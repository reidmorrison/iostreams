# frozen_string_literal: true

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

    # A stream found that it cannot read the data of a file, such as a file within a zip file whose CRC32 is not the one
    # that the zip file records, or a zip file that does not contain the file to read. It is tagged with the kind of
    # failure, such as `Corrupt` or `MissingEntry`, see StreamError.
    class StreamFailure < Error
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

    # A value that is not one of the type of its field in the schema, such as `"abc"` for an integer,
    # see `IOStreams::Stream#schema`.
    class InvalidValue < Error
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

    # Data that is not valid in the encoding that it is read or written in, such as bytes that are not valid UTF-8.
    #
    # It is an `Encoding::UndefinedConversionError`, which was raised before it, so that it can still be rescued as one.
    #
    # Example:
    #   IOStreams.path("data.csv").each(:hash) { |hash| p hash }
    #   # => IOStreams::Errors::InvalidEncoding: "\xFF" is not valid UTF-8 at byte offset 1043 on line 12
    class InvalidEncoding < ::Encoding::UndefinedConversionError
      # Returns [Integer] the offset of the first invalid byte within the data read or written through the encode
      # stream, which is the data after any decompression or decryption.
      attr_reader :byte_offset

      # Returns [Integer] the number of the line that the invalid data is on, counting from 1,
      # or [nil] when the data is not read a line at a time.
      attr_reader :line_number

      # Returns [String] the invalid bytes, as binary, like `Encoding::UndefinedConversionError#error_char`, so that code
      # that rescued that error, which was raised before this one, can still read them.
      attr_reader :error_char

      # Returns [Encoding] the encoding that the invalid bytes were read or written as, binary for data read from a file,
      # and the encoding that they are not valid in, like `Encoding::UndefinedConversionError#source_encoding` and
      # `#destination_encoding`.
      attr_reader :source_encoding, :destination_encoding

      def initialize(message, byte_offset:, line_number: nil, error_char: nil, source_encoding: nil,
                     destination_encoding: nil)
        @byte_offset          = byte_offset
        @line_number          = line_number
        @error_char           = error_char
        @source_encoding      = source_encoding
        @destination_encoding = destination_encoding
        super(message)
      end

      # Returns [String] the name of the #source_encoding, such as "ASCII-8BIT", or nil.
      def source_encoding_name
        source_encoding&.name
      end

      # Returns [String] the name of the #destination_encoding, such as "UTF-8", or nil.
      def destination_encoding_name
        destination_encoding&.name
      end

      # Sets the number of the line that the invalid data is on, unless it is already set.
      def line_number=(line_number)
        @line_number ||= line_number
      end

      def to_s
        text = "#{super} at byte offset #{byte_offset}"
        line_number ? "#{text} on line #{line_number}" : text
      end
    end

    # The display name of the file that failed, and the message that starts with it, for an exception that a kind of
    # failure tags, such as `NotFound` or `Corrupt`. Each family of kinds of failure, StorageError and StreamError,
    # includes it.
    #
    # A kind of failure tags the exception that was raised, rather than replacing it, so that the exception keeps its
    # class, backtrace and attributes, and can still be rescued by its own class.
    module Tagged
      # Returns [String] the display name of the file that failed, which does not include any credentials, see
      # `IOStreams::Path#display_name`, or nil when it is not known.
      def display_name
        @iostreams_display_name
      end

      # Returns [String] the message, starting with the display name, unless it already includes it, or is not known.
      def to_s
        prefix_display_name(super)
      end

      # Returns [String] the message, see #to_s, also for an exception whose class answers its own message, rather than
      # its #to_s, such as `Zip::DecompressionError` of rubyzip.
      def message
        prefix_display_name(super)
      end

      # Adds `.tag` to each kind of failure, such as `NotFound.tag`.
      module Tag
        # Tags the exception with this kind of failure, and the display name of the file that failed, when known.
        #
        # Returns [Exception] the exception. It is unchanged when it is frozen, or when it is already tagged with any
        # kind of failure, for example by a path that failed within a block that another path called, or by the stream
        # that another stream reads.
        def tag(exception, display_name = nil)
          return exception if exception.frozen? || exception.is_a?(Tagged)

          exception.instance_variable_set(:@iostreams_display_name, display_name)
          exception.extend(self)
        end
      end

      # Gives each kind of failure that includes a family, such as `NotFound`, which includes StorageError, `.tag`.
      module Family
        def included(kind)
          super
          kind.extend(Tag)
        end
      end

      def self.included(family)
        super
        family.extend(Family)
      end

      private

      def prefix_display_name(text)
        name = display_name
        name.nil? || text.nil? || text.include?(name) ? text : "#{name}: #{text}"
      end
    end
    private_constant :Tagged

    # Every kind of failure of a stream to read the data of a file, such as `Corrupt`, includes StreamError. A stream,
    # such as gzip or zip, tags the exception that the gem reading its format raised with the kind of failure, rather
    # than replacing it, and raises `StreamFailure` tagged with it for a failure that it finds itself, see
    # `docs/errors.md`.
    #
    # Rescue the kind of failure, rather than the exception of a gem, such as `Zlib::GzipFile::Error` for gzip, so that
    # the code works whichever streams the file name names, for example when a path held in configuration changes from
    # `.gz` to `.zip`, and whichever gem reads the format, which can be replaced by another, or differ by platform.
    #
    # Its message starts with the display name of the file, when the stream knows it, unless the message already
    # includes it.
    #
    # Example:
    #   begin
    #     IOStreams.path("orders.csv.gz").each(:hash) { |record| Order.import(record) }
    #   rescue IOStreams::Errors::Corrupt => e
    #     e.class   # => Zlib::GzipFile::Error
    #     e.message # => "not in gzip format"
    #   end
    module StreamError
      include Tagged
    end

    # The data is not valid in the format of its stream, so that the stream cannot read it: it is damaged, cut short, or
    # not in that format at all, such as a text file named `.gz`, or it uses a part of the format that the stream does not
    # support, such as a zip file encrypted with a password.
    module Corrupt
      include StreamError
    end

    # The file does not contain the entry to read, such as a zip file without the file named by `entry_file_name`, or
    # without any file at all.
    module MissingEntry
      include StreamError
    end

    # Every kind of failure of the storage that a path is on, such as `NotFound`, includes StorageError. A path tags
    # the exception that its storage raised with the kind of failure, rather than replacing it, see `docs/errors.md`.
    #
    # Rescue the kind of failure, rather than the exception that the storage raised, such as `Errno::ENOENT` for a
    # local file or `Aws::S3::Errors::NoSuchKey` for S3, so that the code works whichever storage the path is on,
    # for example when a path held in configuration changes from local files to S3.
    #
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
      include Tagged
    end

    # The file, a directory that it is in, or its S3 bucket, does not exist.
    module NotFound
      include StorageError
    end

    # The storage does not permit the access, or the credentials for it are missing or not valid.
    module PermissionDenied
      include StorageError
    end

    # The storage could not be reached, or could not handle the request at the time, so that the same request can
    # succeed when it is made again later.
    #
    # It also decides which exceptions of a connection to a server mean that, see .network_error?, which each path asks.
    module Unavailable
      include StorageError

      # The exceptions that a connection raises when the server cannot be reached, or the connection to it fails.
      CONNECTION_ERRORS = [
        SocketError, Errno::ECONNABORTED, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
        Errno::ENETUNREACH, Errno::ETIMEDOUT
      ].freeze

      # Returns [true|false] whether the exception, raised by a connection to a server, means that the server could not
      # be reached, or that the connection to it failed, so that the same request can succeed later: it is one of
      # CONNECTION_ERRORS, or of the supplied classes that the protocol of a path also raises for a connection that
      # fails, such as a read timeout, but not a host name that does not resolve, see .unknown_host?.
      def self.network_error?(exception, also: [])
        return false if unknown_host?(exception)

        [*CONNECTION_ERRORS, *also].any? { |error_class| exception.is_a?(error_class) }
      end

      # Returns [true|false] whether the exception is a failure to look up a host name that does not resolve, such as a
      # mistyped host, so that the same request cannot succeed later. A temporary failure of name resolution
      # (`Socket::EAI_AGAIN`), which is how a DNS outage, or a network without DNS, is reported on Linux, is not.
      #
      # Ruby 3.2 does not have `Socket::ResolutionError`, so its `SocketError` is never an unknown host.
      def self.unknown_host?(exception)
        return false unless defined?(::Socket::ResolutionError) && exception.is_a?(::Socket::ResolutionError)

        exception.error_code != ::Socket::EAI_AGAIN
      end
    end
  end
end
