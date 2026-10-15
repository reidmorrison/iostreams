# frozen_string_literal: true

module IOStreams
  class Reader
    # Returns [Array<Symbol>] the names of the options this reader accepts,
    # or [nil] when the reader does not declare them.
    #
    # When declared, only these options are passed to the reader.
    def self.option_names
      nil
    end

    # Returns [Array<Symbol>] the options of the writer of its format that this reader does not support, so that
    # `IOStreams::StreamFormat#validate_options` raises for them when reading, with a message that names the
    # direction that they belong to, rather than ignoring them.
    #
    # One option hash is shared by the reader and the writer for a stream, so that the same path can be
    # written and then read. So by default the writer's options are also valid when reading, and are
    # ignored, since only `option_names` are passed to the reader. List an option of the writer here when a
    # caller could expect it to have an effect when reading, such as the name of the worksheet to write, which
    # must raise until the reader supports it.
    def self.unsupported_option_names
      []
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path or stream does not display them, see `IOStreams::StreamFormat#redact_options`.
    def self.sensitive_option_names
      []
    end

    # Returns [Module] the kind of failure, such as `IOStreams::Errors::Corrupt`, that an exception raised by the gem
    # that reads this format means, or nil when it is none of them, see `IOStreams::Errors::StreamError`.
    #
    # Each reader returns the kinds of failure of its own gem, and makes each call of its gem within `.tag_failure`, so
    # that the caller rescues the kind of failure, rather than the exception of a gem, which can be replaced by another.
    # A reader registered with `IOStreams.register_extension` can do the same.
    def self.failure_kind(_exception)
      nil
    end

    # Calls the block, which calls the gem that reads this format, and tags an exception that it raises with the kind of
    # failure that it means, see `.failure_kind`, and the display name of the file that is read, when it is known.
    #
    # Only call the gem within the block, never a block that the caller supplied, since an exception raised by the
    # caller's block, such as a `Zlib::GzipFile::Error` from another gzip file, is not a failure of this stream.
    def self.tag_failure(display_name = nil)
      yield
    rescue StandardError => e
      kind = failure_kind(e)
      raise unless kind

      raise(kind.tag(e, display_name))
    end

    # When a Reader does not support streams, it reads the file of the stream when the stream is already
    # a local file, see `.input_file_name`. Otherwise the stream is copied to a local temp file,
    # and that file name is passed to this reader.
    def self.stream(input_stream, **args, &block)
      local_file_name = input_file_name(input_stream)
      if local_file_name
        result = file(local_file_name, **args, &block)
        # Leave the stream at its end, as if it had been copied.
        input_stream.seek(0, ::IO::SEEK_END)
        return result
      end

      purpose = "a copy of the input of #{self}, which only reads files"
      Utils.private_temp_file("iostreams_reader", purpose: purpose) do |file_name|
        ::File.open(file_name, "wb") { |target| ::IO.copy_stream(input_stream, target) }
        file(file_name, **args, &block)
      end
    end

    # Returns [String] the name of the local file that the input stream reads, which a reader can read by its name,
    # such as a reader that only reads files, instead of a copy of the stream, see `Utils.local_file_name`.
    # Returns nil for any other stream, including a file that was not opened for reading, so that reading it raises,
    # rather than opening the file again to read it.
    #
    # Since the reader opens the file again by its name, also returns nil unless the name can be opened, and still
    # refers to the same file, for example after the file's permissions changed, or the process gave up the
    # privileges it opened the file with, so that the stream is copied instead.
    def self.input_file_name(input_stream)
      file_name = Utils.local_file_name(input_stream)
      return unless file_name

      # Raises IOError when the file was not opened for reading, without reading from it.
      input_stream.read(0)
      ::File.open(file_name, "rb") { |file| file_name if ::File.identical?(file, Utils.local_file(input_stream)) }
    rescue IOError, SystemCallError
      nil
    end
    private_class_method :input_file_name

    # When a Reader supports streams, also allow it to simply support a file
    def self.file(file_name, **args, &block)
      ::File.open(file_name, "rb") { |file| stream(file, **args, &block) }
    end

    # For processing by either a file name or an open IO stream.
    def self.open(file_name_or_io, **args, &)
      file_name_or_io.is_a?(String) ? file(file_name_or_io, **args, &) : stream(file_name_or_io, **args, &)
    end

    attr_reader :input_stream

    def initialize(input_stream)
      @input_stream = input_stream
    end
  end
end
