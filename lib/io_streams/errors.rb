module IOStreams
  module Errors
    class Error < StandardError
    end

    class InvalidHeader < Error
    end

    class MissingHeader < Error
    end

    class UnknownFormat < Error
    end

    class TypeMismatch < Error
    end

    class CommunicationsFailure < Error
    end

    # When a path is not within any of the allowed paths, see `IOStreams.add_allowed_path`.
    #
    # IOStreams raises it to enforce the access that the application allows, so it is not a `PermissionDenied`,
    # which is a failure of the storage.
    class AccessDenied < Error
    end

    # When the specified delimiter is not found in the supplied stream / file
    class DelimiterNotFound < Error
    end

    # Fixed length line has the wrong length
    class InvalidLineLength < Error
    end

    class ValueTooLong < Error
    end

    class MalformedDataError < RuntimeError
      attr_reader :line_number

      def initialize(message, line_number)
        @line_number = line_number
        super("#{message} on line #{line_number}.")
      end
    end

    class InvalidLayout < Error
    end

    # Every kind of failure of the storage that a path is on, such as `NotFound`, includes StorageError. A path tags
    # the exception that its storage raised with the kind of failure, rather than replacing it, see `docs/errors.md`.
    #
    # Rescue the kind of failure, rather than the exception that the storage raised, such as `Errno::ENOENT` for a
    # local file or `Aws::S3::Errors::NoSuchKey` for S3, so that the code works whichever storage the path is on,
    # for example when a path held in configuration changes from local files to S3.
    #
    # A tagged exception keeps its class, backtrace and attributes, so that it can still be rescued by its own class.
    # Its message starts with the display name of the path, unless the message already includes it.
    #
    # Example:
    #   begin
    #     IOStreams.path("s3://my-bucket/data/report.csv").read
    #   rescue IOStreams::Errors::NotFound => e
    #     e.display_name # => "s3://my-bucket/data/report.csv"
    #     e.message      # => "s3://my-bucket/data/report.csv: The specified key does not exist."
    #   end
    module StorageError
      # Returns [String] the display name of the path whose storage failed, which does not include any credentials,
      # see `IOStreams::Path#display_name`.
      def display_name
        @iostreams_display_name
      end

      # Returns [String] the message, starting with the display name of the path, unless it already includes it.
      def to_s
        text = super
        name = display_name
        name.nil? || text.include?(name) ? text : "#{name}: #{text}"
      end

      # Adds `.tag` to each kind of failure, such as `NotFound.tag`.
      module Tag
        # Tags the exception with this kind of failure, and the display name of the path whose storage raised it.
        #
        # Returns [Exception] the exception. It is unchanged when it is frozen, or when it is already tagged, for
        # example by a path that failed within a block that another path called.
        def tag(exception, display_name)
          return exception if exception.frozen? || exception.is_a?(StorageError)

          exception.instance_variable_set(:@iostreams_display_name, display_name)
          exception.extend(self)
        end
      end
      private_constant :Tag

      # Each kind of failure that includes StorageError, such as `NotFound`, answers `.tag`.
      def self.included(kind)
        super
        kind.extend(Tag)
      end
    end

    # The file, a directory that it is in, or its S3 bucket, does not exist.
    module NotFound
      include StorageError
    end

    # The storage does not permit the access, or the credentials for it are missing or not valid.
    module PermissionDenied
      include StorageError
    end
  end
end
