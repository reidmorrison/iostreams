module IOStreams
  class Writer
    # Returns [Array<Symbol>] the names of the options this writer accepts,
    # or [nil] when the writer does not declare them.
    #
    # When declared, only these options are passed to the writer.
    def self.option_names
      nil
    end

    # Returns [Array<Symbol>] the names of the options that are valid when writing the stream,
    # or [nil] to accept the options of both the reader and the writer of its format,
    # see `IOStreams::StreamFormat#valid_option_names`.
    #
    # `IOStreams::Builder` rejects any other option before the writer is opened, naming the direction
    # an option belongs to when it is only valid for the other direction.
    #
    # One option hash is shared by the reader and the writer for a stream, so that the same path can be
    # written and then read. So by default the reader's options are also valid when writing, and are
    # ignored, since only `option_names` are passed to the writer. Override this to exclude an option of
    # the reader that a caller could expect to have an effect when writing, which must raise until the
    # writer supports it.
    def self.valid_option_names
      nil
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path or stream does not display them, see `IOStreams::StreamFormat#redact_options`.
    def self.sensitive_option_names
      []
    end

    # When a Writer does not support streams, it writes to the file of the stream when the stream is an
    # empty local file, see `Utils.local_file_name`. Otherwise it writes to a local temp file, which is
    # then copied to the stream.
    def self.stream(output_stream, **args, &block)
      local_file_name = Utils.local_file_name(output_stream)
      if local_file_name && output_stream.stat.zero?
        result = file(local_file_name, **args, &block)
        # So that anything written to the stream next follows the data, as if it had been copied to the stream.
        output_stream.seek(0, ::IO::SEEK_END)
        return result
      end

      Utils.private_temp_file("iostreams_writer") do |file_name|
        count = file(file_name, **args, &block)
        ::File.open(file_name, "rb") { |source| ::IO.copy_stream(source, output_stream) }
        count
      end
    end

    # When a Writer supports streams, also allow it to simply support a file
    def self.file(file_name, **args, &block)
      ::File.open(file_name, "wb") { |file| stream(file, **args, &block) }
    end

    # For processing by either a file name or an open IO stream.
    def self.open(file_name_or_io, **args, &)
      file_name_or_io.is_a?(String) ? file(file_name_or_io, **args, &) : stream(file_name_or_io, **args, &)
    end

    attr_reader :output_stream

    def initialize(output_stream)
      @output_stream = output_stream
    end
  end
end
