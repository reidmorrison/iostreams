# frozen_string_literal: true

module IOStreams
  class Writer
    # Returns [Array<Symbol>] the names of the options this writer accepts,
    # or [nil] when the writer does not declare them.
    #
    # When declared, only these options are passed to the writer.
    def self.option_names
      nil
    end

    # Returns [Array<Symbol>] the options of the reader of its format that this writer does not support, so that
    # `IOStreams::StreamFormat#validate_options` raises for them when writing, with a message that names the
    # direction that they belong to, rather than ignoring them.
    #
    # One option hash is shared by the reader and the writer for a stream, so that the same path can be
    # written and then read. So by default the reader's options are also valid when writing, and are
    # ignored, since only `option_names` are passed to the writer. List an option of the reader here when a
    # caller could expect it to have an effect when writing, such as the name of the worksheet to write, which
    # must raise until the writer supports it.
    def self.unsupported_option_names
      []
    end

    # Returns [Array<Symbol>] the names of the options whose values must not be displayed, such as a passphrase,
    # so that `#inspect` on a path or stream does not display them, see `IOStreams::StreamFormat#redact_options`.
    def self.sensitive_option_names
      []
    end

    # When a Writer does not support streams, it writes to a local temp file, which is then copied to the stream
    # once the writer has completed, so that the stream never holds partial output when the writer fails.
    #
    # The file is copied when the block returns, including when it leaves early, such as with `break`, which keeps
    # what was written so far, as a writer that supports streams does. It is not copied when the block raises, or its
    # thread is killed.
    def self.stream(output_stream, **args, &block)
      purpose = "the output of #{self}, which only writes files"
      Utils.private_temp_file("iostreams_writer", purpose: purpose) do |file_name|
        copy = -> { ::File.open(file_name, "rb") { |source| ::IO.copy_stream(source, output_stream) } }
        Utils.finish_or_abort(finish: copy) { file(file_name, **args, &block) }
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
