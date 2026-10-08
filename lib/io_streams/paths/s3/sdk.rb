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
        def self.available?
          load
          true
        rescue LoadError
          false
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
          names - OPERATIONS.flat_map { |operation| operation_options(operation) }
        end
      end
    end
  end
end
