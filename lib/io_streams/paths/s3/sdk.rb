module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # The AWS SDK, which is loaded when it is first needed, rather than when a path is created, so that a path can be
      # created, joined, compared and displayed in a process without the `aws-sdk-s3` gem, such as one that only
      # enqueues work. Also the S3 operations that a path calls, and the options that the SDK accepts for each one.
      module Sdk
        # The S3 operations that a path calls, each of which is supplied the options that it accepts.
        OPERATIONS = %i[get_object head_object put_object copy_object delete_object delete_objects list_objects_v2].freeze
        # Request parameters that the path sets itself, which cannot be supplied as options.
        PATH_PARAMETERS = %i[bucket key body response_target copy_source prefix continuation_token delete].freeze

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

        # Returns [true|false] whether the loaded AWS SDK has `Aws::S3::TransferManager`.
        def self.transfer_manager?
          !defined?(::Aws::S3::TransferManager).nil?
        end

        # Returns [Array<Symbol>] the options that the S3 operation accepts.
        def self.operation_options(operation)
          load
          @operation_options ||= {}
          @operation_options[operation] ||=
            (::Aws::S3::Client.api.operation(operation).input.shape.member_names - PATH_PARAMETERS).freeze
        end

        # Returns [Array<Symbol>] the supplied option names that no S3 operation accepts.
        def self.unknown_options(names)
          @known_options ||= OPERATIONS.flat_map { |operation| operation_options(operation) }.uniq.freeze
          names - @known_options
        end
      end
    end
  end
end
