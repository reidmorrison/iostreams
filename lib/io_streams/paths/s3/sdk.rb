# frozen_string_literal: true

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # The AWS SDK, which is loaded when it is first needed, rather than when a path is created, so that a path can be
      # created, joined, compared and displayed in a process without the `aws-sdk-s3` gem, such as one that only
      # enqueues work. Also the S3 operations that a path calls, and the options that the SDK accepts for each one.
      module Sdk
        # The S3 operations that a path calls, each of which is supplied the options that it accepts.
        OPERATIONS = %i[get_object head_object put_object copy_object delete_object delete_objects list_objects_v2].freeze
        # Request parameters that the path sets itself, which cannot be supplied as options, and the parameters of a
        # listing that would change which keys it returns, or how, such as `encoding_type: "url"`, which encodes them.
        PATH_PARAMETERS = %i[
          bucket key body response_target copy_source prefix continuation_token delimiter delete encoding_type start_after
        ].freeze
        # The options of an object that S3 needs to read it as the source of a direct copy, and the parameter of
        # `copy_object` that supplies each one: its customer encryption key, and that the requester pays, which a
        # bucket can require to read it.
        COPY_SOURCE_OPTIONS = {
          sse_customer_algorithm: :copy_source_sse_customer_algorithm,
          sse_customer_key:       :copy_source_sse_customer_key,
          sse_customer_key_md5:   :copy_source_sse_customer_key_md5,
          request_payer:          :request_payer
        }.freeze

        # Loads the AWS SDK, unless it is already loaded. Raises LoadError when the `aws-sdk-s3` gem is not installed.
        #
        # Every method that names an AWS constant, including in a `rescue` clause, calls it first, outside of that
        # clause, since Ruby resolves the constant when an exception reaches the clause, which would otherwise raise
        # `NameError` in place of the exception, such as the `LoadError` of a missing gem.
        def self.load
          Utils.load_soft_dependency("aws-sdk-s3", "AWS S3") unless defined?(::Aws::S3::Client)
        end

        # Returns [true|false] whether the AWS SDK is loaded, or can be, since the `aws-sdk-s3` gem is installed.
        # Raises LoadError when the gem is installed but cannot be loaded, see `Utils.soft_dependency_installed?`.
        #
        # Remembers that the gem is not installed, so that it is not searched for again each time.
        def self.available?
          return true if defined?(::Aws::S3::Client)
          return false if @not_installed

          installed = Utils.soft_dependency_installed?("aws-sdk-s3", "AWS S3")
          @not_installed = true unless installed
          installed
        end

        # Uploads the file, in parts once it reaches the SDK's `multipart_threshold`, supplying each request with the
        # options that it accepts.
        #
        # Uses `Aws::S3::TransferManager`, which `aws-sdk-s3` added in v1.197.0 when it deprecated
        # `Aws::S3::Object#upload_file`, and that deprecated method with an earlier version of the gem.
        def self.upload_file(client, file_name, bucket:, key:, **options)
          load
          if transfer_manager?
            ::Aws::S3::TransferManager.new(client: client).upload_file(file_name, bucket: bucket, key: key, **options)
          else
            ::Aws::S3::Resource.new(client: client).bucket(bucket).object(key).upload_file(file_name, options)
          end
        end

        # Returns [true|false] whether the client of the loaded AWS SDK takes the option, such as
        # `request_checksum_calculation`, which only its newer versions take. Load the AWS SDK first, see `.load`.
        def self.client_option?(name)
          ::Aws::S3::Client.plugins.any? do |plugin|
            plugin.respond_to?(:options) && plugin.options.any? { |option| option.name == name }
          end
        end

        # Returns [true|false] whether the loaded AWS SDK has `Aws::S3::TransferManager`.
        def self.transfer_manager?
          !defined?(::Aws::S3::TransferManager).nil?
        end

        # Returns [Array<Symbol>] the options that the S3 operation accepts.
        def self.operation_options(operation)
          load
          cached = @operation_options&.[](operation)
          return cached if cached

          names = (::Aws::S3::Client.api.operation(operation).input.shape.member_names - PATH_PARAMETERS).freeze
          # Replaces the cache rather than changing it, since the parts of an upload are requested in several threads.
          @operation_options = (@operation_options || {}).merge(operation => names).freeze
          names
        end

        # Returns [Hash] the parameters of `copy_object` that supply the options of its source that S3 needs to read it,
        # see COPY_SOURCE_OPTIONS, such as `copy_source_sse_customer_key` for the source's `sse_customer_key`.
        def self.copy_source_options(options)
          COPY_SOURCE_OPTIONS.each_with_object({}) do |(option, parameter), parameters|
            parameters[parameter] = options[option] if options.key?(option)
          end
        end

        # Returns [Array<Symbol>] the supplied option names that no S3 operation accepts. None without any names, so
        # that the AWS SDK is not loaded, nor without the SDK, which the names cannot be checked without.
        def self.unknown_options(names)
          return [] if names.empty? || !available?

          @known_options ||= OPERATIONS.flat_map { |operation| operation_options(operation) }.uniq.freeze
          names - @known_options
        end
      end
    end
  end
end
