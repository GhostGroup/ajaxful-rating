module AjaxfulRating # :nodoc:
  include AjaxfulRating::Errors

  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    # Extends the model to be easy ajaxly rateable.
    #
    # Options:
    # * <tt>:stars</tt> Max number of stars that can be submitted.
    # * <tt>:allow_update</tt> Set to true if you want users to be able to update their votes.
    # * <tt>:cache_column</tt> Name of the column for storing the cached rating average.
    #
    # Example:
    #   class Article < ActiveRecord::Base
    #     ajaxful_rateable :stars => 10, :cache_column => :custom_column
    #   end
    def ajaxful_rateable(options = {})
      options[:class_name] ||= :Rate
      has_many :rates_without_dimension, -> { where(:dimension => nil) }, :as => :rateable, :class_name => options[:class_name], :dependent => :destroy
      has_many :raters_without_dimension, :through => :rates_without_dimension, :source => :rater

      class << self
        def axr_config(dimension = nil)
          dimension ||= :default
          @axr_config ||= {}
          dimension = dimension.to_sym
          @axr_config[dimension] ||= {
            :stars => 5,
            :allow_update => true,
            :cache_column => :rating_average
          }
        end

        alias_method :ajaxful_rating_options, :axr_config
      end

      if options[:dimensions].is_a?(Array)
        options[:dimensions].each do |dimension|
          has_many :"#{dimension}_rates", -> { where(:dimension => dimension.to_s) }, :dependent => :destroy, :class_name => :Rate, :as => :rateable
          has_many :"#{dimension}_raters", :through => :"#{dimension}_rates", :source => :rater

          axr_config(dimension).update(options)
        end
      else
          axr_config.update(options)
      end


      include AjaxfulRating::InstanceMethods
      extend AjaxfulRating::SingletonMethods
    end

    # Makes the association between user and Rate model.
    def ajaxful_rater(options = {})
      has_many :ratings_given, options.merge(:class_name => :Rate, :foreign_key => :rater_id)
    end
  end

  # Instance methods for the rateable object.
  module InstanceMethods

    # Proxy for axr_config singleton method.
    def axr_config(dimension = nil)
      self.class.axr_config(dimension)
    end

    # Submits a new rate. Accepts a hash of tipical Ajax request.
    #
    # Example:
    #   # Articles Controller
    #   def rate
    #     @article = Article.find(params[:id])
    #     @article.rate(params[:stars], current_user, params[:dimension])
    #     # some page update here ...
    #   end
    def rate(stars, user, dimension = nil)
      return false if (stars.to_i > self.class.max_stars) || (stars.to_i < 1)
      raise Errors::AlreadyRatedError if (!self.class.axr_config(dimension)[:allow_update] && rated_by?(user, dimension))

      rate = if self.class.axr_config(dimension)[:allow_update] && rated_by?(user, dimension)
        rate_by(user, dimension)
      else
        rates(dimension).build.tap do |r|
          r.rater = user
        end
      end
      rate.stars = stars
      rate.save!
      self.update_cached_average(dimension)
    end

    # Builds the DOM id attribute for the wrapper in view.
    def wrapper_dom_id(options = {})
      options = options.to_hash.symbolize_keys.slice(:small, :dimension)
      options = options.map do |k, v|
        if k == :dimension
          v.to_s
        else
          v.to_s == 'true' ? k.to_s : "no-#{k}"
        end
      end
      options = options.delete_if { |x| x.empty? }
      prefix = "ajaxful_rating"
      prefix << "_#{options.sort.join('_')}" unless options.empty?
      ApplicationController.helpers.dom_id(self, prefix)
    end

    # Returns an array with the users that have rated this object for the
    # passed dimension.
    #
    # It may works as an alias for +dimension_raters+ methods.
    def raters(dimension = nil)
      sql = "SELECT DISTINCT u.* FROM #{self.class.user_class.table_name} u "\
        "INNER JOIN rates r ON u.id = r.rater_id WHERE "

      # Code lifted from https://github.com/rails/rails/blob/d5902c9e7eaba4db4e79c464d623a7d7e6e2d0e3/activerecord/lib/active_record/sanitization.rb#L89 to avoid deprecation warning
      table = Arel::Table.new(self.class.table_name, self.class.arel_engine).alias('r')
      attrs = {
        :rateable_id => id,
        :rateable_type => self.class.base_class.name,
        :dimension => (dimension.to_s if dimension)
      }
      sql << ActiveRecord::PredicateBuilder.build_from_hash(self.class, attrs, table).map { |b| self.class.connection.visitor.compile b }.join(' AND ')

      self.class.user_class.find_by_sql(sql)
    end

    # Finds the rate made by the user if he/she has already voted.
    def rate_by(user, dimension = nil)
      rates(dimension).find_by_rater_id(user.id)
    end

    # Return true if the user has rated the object, otherwise false
    def rated_by?(user, dimension = nil)
      !rate_by(user, dimension).nil?
    end

    # Returns whether or not the user can rate this object.
    # Based on if the user has already rated the object or the
    # :allow_update option is enabled.
    def can_rate_by?(user, dimension = nil)
      !rated_by?(user, dimension) || self.class.axr_config(dimension)[:allow_update]
    end

    # Instance's total rates.
    def total_rates(dimension = nil)
      rates(dimension).size
    end

    # Total sum of the rates.
    def rates_sum(dimension = nil)
      rates(dimension).sum(:stars)
    end

    # Rating average for the object.
    #
    # Pass false as param to force the calculation if you are caching it.
    def rate_average(cached = true, dimension = nil)
      avg = if cached && self.class.caching_average?(dimension)
        send(caching_column_name(dimension)).to_f
      else
        self.rates_sum(dimension).to_f / self.total_rates(dimension).to_f
      end
      avg.nan? ? 0.0 : avg
    end

    # Overrides the default +rates+ method and returns the propper array
    # for the dimension passed.
    #
    # It may works as an alias for +dimension_rates+ methods.
    def rates(dimension = nil)
      unless dimension.blank?
        send("#{dimension}_rates")
      else
        rates_without_dimension
      end
    end

    # Returns the name of the cache column for the passed dimension.
    def caching_column_name(dimension = nil)
      self.class.caching_column_name(dimension)
    end

    # Updates the cached average column in the rateable model.
    def update_cached_average(dimension = nil)
      if self.class.caching_average?(dimension)
        update_attribute caching_column_name(dimension), self.rate_average(false, dimension)
      end
    end
  end

  module SingletonMethods

    # Maximum value accepted when rating the model. Default is 5.
    #
    # Change it by passing the :stars option to +ajaxful_rateable+
    #
    #   ajaxful_rateable :stars => 10
    def max_stars(dimension = nil)
      axr_config(dimension)[:stars]
    end

    # Name of the class for the user model.
    def user_class_name
      Rate.reflect_on_association(:rater).options[:class_name]
    end

    # Gets the user's class
    def user_class
      user_class_name.constantize
    end

    # Finds all rateable objects rated by the +user+.
    def find_rated_by(user, dimension = nil)
      find_statement(:rater_id, user.id, dimension)
    end

    # Finds all rateable objects rated with +stars+.
    def find_rated_with(stars, dimension = nil)
      find_statement(:stars, stars, dimension)
    end

    # Finds the rateable object with the highest rate average.
    def find_most_popular(dimension = nil)
      all.sort_by { |o| o.rate_average(true, dimension) }.last
    end

    # Finds the rateable object with the lowest rate average.
    def find_less_popular(dimension = nil)
      all.sort_by { |o| o.rate_average(true, dimension) }.first
    end

    # Finds rateable objects by Rate's attribute.
    def find_statement(attr_name, attr_value, dimension = nil)
      sql = "SELECT DISTINCT r2.* FROM rates r1 INNER JOIN "\
        "#{self.base_class.table_name} r2 ON r1.rateable_id = r2.id WHERE "

      # Code lifted from https://github.com/rails/rails/blob/d5902c9e7eaba4db4e79c464d623a7d7e6e2d0e3/activerecord/lib/active_record/sanitization.rb#L89 to avoid deprecation warning
      table = Arel::Table.new(table_name, arel_engine).alias('r1')
      attrs = {
        :rateable_type => self.base_class.name,
        attr_name => attr_value,
        :dimension => (dimension.to_s if dimension)
      }
      sql << ActiveRecord::PredicateBuilder.build_from_hash(self, attrs, table).map { |b| connection.visitor.compile b }.join(' AND ')

      find_by_sql(sql)
    end

    # Indicates if the rateable model is able to cache the rate average.
    #
    # Include a column named +rating_average+ in your rateable model with
    # default null, as decimal:
    #
    #   t.decimal :rating_average, :precision => 3, :scale => 1, :default => 0
    #
    # To customize the name of the column specify the option <tt>:cache_column</tt> to ajaxful_rateable
    #
    #   ajaxful_rateable :cache_column => :my_custom_column
    #
    def caching_average?(dimension = nil)
      column_names.include?(caching_column_name(dimension))
    end

    # Returns the name of the cache column for the passed dimension.
    def caching_column_name(dimension = nil)
      name = axr_config(dimension)[:cache_column].to_s
      name += "_#{dimension.to_s.underscore}" unless dimension.blank?
      name
    end
  end
end

class ActiveRecord::Base
  include AjaxfulRating
end
