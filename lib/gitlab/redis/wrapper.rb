# This file should only be used by sub-classes, not directly by any clients of the sub-classes
# please require all dependencies below:
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/module/delegation'

module Gitlab
  module Redis
    class Wrapper
      DEFAULT_REDIS_URL = 'redis://localhost:6379'.freeze
      REDIS_CONFIG_ENV_VAR_NAME = 'GITLAB_REDIS_CONFIG_FILE'.freeze
      if defined?(::Rails) && ::Rails.root.present?
        DEFAULT_REDIS_CONFIG_FILE_NAME = ::Rails.root.join('config', 'resque.yml').freeze
      end

      class << self
        delegate :params, :url, to: :new

        def with
          @pool ||= ConnectionPool.new(size: pool_size) { ::Redis.new(params) }
          @pool.with { |redis| yield redis }
        end

        def pool_size
          # heuristic constant 5 should be a config setting somewhere -- related to CPU count?
          size = 5
          if Sidekiq.server?
            # the pool will be used in a multi-threaded context
            size += Sidekiq.options[:concurrency]
          end
          size
        end

        def _raw_config
          return @_raw_config if defined?(@_raw_config)

          begin
            @_raw_config = ERB.new(File.read(config_file_name)).result.freeze
          rescue Errno::ENOENT
            @_raw_config = false
          end

          @_raw_config
        end

        def default_url
          DEFAULT_REDIS_URL
        end

        def config_file_name
          # if ENV set for wrapper class, use it even if it points to a file does not exist
          file_name = ENV[REDIS_CONFIG_ENV_VAR_NAME]
          return file_name unless file_name.nil?

          # otherwise, if config files exists for wrapper class, use it
          file_name = File.expand_path(DEFAULT_REDIS_CONFIG_FILE_NAME, __dir__)
          return file_name if File.file?(file_name)

          # nil will force use of DEFAULT_REDIS_URL when config file is absent
          nil
        end
      end

      def initialize(rails_env = nil)
        @rails_env = rails_env || ::Rails.env
      end

      def params
        redis_store_options
      end

      def url
        raw_config_hash[:url]
      end

      def sentinels
        raw_config_hash[:sentinels]
      end

      def sentinels?
        sentinels && !sentinels.empty?
      end

      private

      def redis_store_options
        config = raw_config_hash
        redis_url = config.delete(:url)
        redis_uri = URI.parse(redis_url)

        if redis_uri.scheme == 'unix'
          # Redis::Store does not handle Unix sockets well, so let's do it for them
          config[:path] = redis_uri.path
          query = redis_uri.query
          unless query.nil?
            queries = CGI.parse(redis_uri.query)
            db_numbers = queries["db"] if queries.key?("db")
            config[:db] = db_numbers[0].to_i if db_numbers.any?
          end
          config
        else
          redis_hash = ::Redis::Store::Factory.extract_host_options_from_uri(redis_url)
          # order is important here, sentinels must be after the connection keys.
          # {url: ..., port: ..., sentinels: [...]}
          redis_hash.merge(config)
        end
      end

      def raw_config_hash
        config_data = fetch_config

        if config_data
          config_data.is_a?(String) ? { url: config_data } : config_data.deep_symbolize_keys
        else
          { url: self.class.default_url }
        end
      end

      def fetch_config
        self.class._raw_config ? YAML.load(self.class._raw_config)[@rails_env] : false
      end
    end
  end
end
