# frozen_string_literal: true

module IOStreams
  # A format registered with `IOStreams.register_extension`, such as `IOStreams::Gzip`, which opens its reader
  # and writer classes with the options that they use.
  #
  # A format extends this module, and answers `reader_class` and `writer_class`.
  #
  # One option hash is shared by a stream's reader and writer, so that the same path can be written and then
  # read. So by default the options of the other direction are also valid, and are ignored, such as `compress`
  # when reading `.enc`, whose header records it. A class can exclude an option of the other direction by
  # listing it in its `unsupported_option_names`, so that it raises, with a message that names the direction it
  # belongs to.
  module StreamFormat
    # The methods that a format answers itself, see `IOStreams.register_extension`. Extending this module gives it the
    # others that a registered format must respond to.
    FORMAT_METHODS = %i[reader_class writer_class compressed? encrypted?].freeze

    # Returns [Array<Symbol>] the methods that a format registered with `IOStreams.register_extension` must respond to,
    # but the supplied format does not: those that it answers itself, see `FORMAT_METHODS`, and those that extending
    # this module gives it.
    def self.missing_methods(format)
      (FORMAT_METHODS + public_instance_methods(false).sort).reject { |name| format.respond_to?(name) }
    end

    # Returns [Array<Symbol>] the options that the class reading (type: :reader) or writing (:writer) this
    # format uses, which are the only options supplied to it, or [nil] when the class does not declare them.
    def option_names(type)
      klass = stream_class(type)
      klass.option_names if klass.respond_to?(:option_names)
    end

    # Returns [Array<Symbol>] the options that are valid when reading (type: :reader) or writing (:writer)
    # this format, or when either (nil), or [nil] when they are not checked, since a class does not declare
    # its options, which a class registered via `IOStreams.register_extension` need not.
    #
    # They are the class's own options and those of the class for the other direction, except those of the other
    # direction that the class does not support, see `IOStreams::Reader.unsupported_option_names`. When the class for
    # the other direction does not declare its options, only the class's own are valid.
    def valid_option_names(type = nil)
      return valid_option_names_for_either if type.nil?

      own = option_names(type)
      return if own.nil?

      klass       = stream_class(type)
      unsupported = klass.respond_to?(:unsupported_option_names) ? klass.unsupported_option_names : []
      own | ((option_names(other_type(type)) || []) - unsupported)
    end

    # Returns [Symbol|nil] the tabular format of the text that the reader of this format returns, and its writer
    # accepts, when the format itself decides it, such as `:csv` for a spreadsheet, whose cells are read and
    # written as CSV, otherwise nil, for a format whose data is the text, such as gzip. The lines of text that a
    # format decides are its own, rather than the lines of the file, so the slices of its rows have no line numbers,
    # see `IOStreams::Builder#lines_of_file?`.
    #
    # The rows and records of a path are read and written in this format when this stream is the one closest to
    # the application, see `IOStreams::Builder#text_format`, whatever format the file name has before it.
    def text_format
      nil
    end

    # Returns [Array<Symbol>] the options whose values must not be displayed, such as a passphrase, as declared
    # by the reader and the writer with `sensitive_option_names`.
    def sensitive_option_names
      %i[reader writer].flat_map do |type|
        klass = stream_class(type)
        (klass.sensitive_option_names if klass.respond_to?(:sensitive_option_names)) || []
      end.uniq
    end

    # Returns [Hash] the options with the value of each sensitive option replaced with "[FILTERED]", so that
    # they can be displayed, for example by `#inspect`.
    #
    # Sensitive options are those that the reader or the writer declares, see #sensitive_option_names, and,
    # as a precaution, any option whose name suggests a secret, such as one that contains `password` or `token`, see
    # `IOStreams::Utils.redact_options`, which owns that list.
    def redact_options(options)
      Utils.redact_options(options, sensitive_option_names)
    end

    # Raises [ArgumentError] unless every option is valid when reading (type: :reader) or writing (:writer)
    # this format, see #valid_option_names, or, when type is nil, valid for either, since it is not yet known
    # which will be used. Options are not checked when the class does not declare them.
    #
    # The message names the stream as it was set, such as `:gz` or `:gzip`, which is supplied as `name`,
    # and the direction that an option only applies to.
    def validate_options(type, options, name:)
      valid = valid_option_names(type)
      return if valid.nil?

      unknown = options.keys - valid
      return if unknown.empty?

      message = type.nil? ? unknown_options_message(unknown, valid, name) : invalid_options_message(type, unknown, valid, name)
      raise(ArgumentError, message)
    end

    # Opens the class that reads (type: :reader) or writes (:writer) this format on the supplied io stream,
    # yielding the stream that reads or writes the data. Returns the result of the block.
    #
    # The options are validated, see #validate_options, and only those that the class uses are supplied to it,
    # leaving out those that are valid but that it does not need, such as `compress` when reading `.enc`.
    # A class can default its options from the file name, such as the name of the file within a zip file,
    # by answering `.file_name_options`. A reader that names the file in its failures, such as zip, declares
    # `.takes_display_name?`, see `IOStreams::Reader.takes_display_name?`, and is supplied `display_name:`.
    #
    # Parameters
    #   name: [Symbol]
    #     The name that the stream was set with, such as `:gz` or `:gzip`, for error messages.
    #
    #   file_name: [String]
    #     The name of the file being read or written, when known.
    #
    #   display_name: [String]
    #     The name that identifies the file being read in failures, such as the url of a path, see
    #     `IOStreams::Path#display_name`, when known.
    #
    #   arguments: [Hash]
    #     The keyword arguments that the caller supplies, rather than the options set on the stream, so that they are
    #     neither validated nor sliced as options are, such as the schema of the records of a Parquet file, which is set
    #     on the path, see `IOStreams::Tabular#write_rows`.
    def open_stream(type, io_stream, options, name:, file_name: nil, display_name: nil, arguments: nil, &)
      klass = registered_class(type, name)
      klass.open(io_stream, **stream_arguments(type, options, name, file_name, arguments, display_name: display_name), &)
    end

    # Raises what #open_stream would raise before the class reads or writes anything, so that the caller can check
    # before it opens the output, which would replace an existing file, see `IOStreams::Stream#open_rows_writer`. The
    # options are validated, see #validate_options, and those that the class uses, with the arguments, are supplied to
    # its `.check`, when it has one, such as `IOStreams::Parquet::Writer.check`. See #open_stream for the parameters.
    def check_stream(type, options, name:, file_name: nil, display_name: nil, arguments: nil)
      klass     = registered_class(type, name)
      arguments = stream_arguments(type, options, name, file_name, arguments, display_name: display_name)
      klass.check(**arguments) if klass.respond_to?(:check)
    end

    private

    # Returns [true|false] whether the class names the file that it reads in its failures, so that it takes
    # `display_name:`, see `IOStreams::Reader.takes_display_name?`.
    def takes_display_name?(klass)
      klass.respond_to?(:takes_display_name?) && klass.takes_display_name?
    end

    def registered_class(type, name)
      stream_class(type) || raise(ArgumentError, "No #{type} registered for Stream type: #{name.inspect}")
    end

    # Returns [Hash] the keyword arguments that the class is opened with: the options that it uses, once they are
    # validated, the display name of the file when the class takes it, and the arguments of the caller, see #open_stream.
    def stream_arguments(type, options, name, file_name, arguments, display_name: nil)
      validate_options(type, options, name: name)
      klass    = stream_class(type)
      accepted = option_names(type)
      options  = options.slice(*accepted) if accepted
      options  = klass.file_name_options(file_name, **options) if file_name && klass.respond_to?(:file_name_options)
      options  = options.merge(display_name: display_name) if display_name && takes_display_name?(klass)
      options  = options.merge(arguments) if arguments
      options
    end

    # Options are checked when they are set, against those that are valid when either reading or writing,
    # since it is not yet known which will be used. Not checked when the reader or the writer does not
    # declare its options.
    def valid_option_names_for_either
      types = %i[reader writer].select { |type| stream_class(type) }
      names = types.map { |type| valid_option_names(type) }
      return if names.empty? || names.include?(nil)

      valid = names.flatten
      # The reader's options and then the writer's, in the order that they declare them.
      (types.flat_map { |type| option_names(type) || [] } + valid).uniq & valid
    end

    # Returns [String] the message for options that are not valid in either direction.
    def unknown_options_message(unknown, valid, name)
      "Unknown #{unknown.size == 1 ? 'option' : 'options'} #{list(unknown)} for a #{name.inspect} stream. " \
        "Valid options: #{list(valid)}."
    end

    # Returns [String] the message for options that are not valid when reading or writing, naming the other
    # direction for those that only apply to it.
    def invalid_options_message(type, unknown, valid, name)
      other_names = option_names(other_type(type)) || []
      other_only  = unknown & other_names
      invalid     = unknown - other_names
      direction   = type == :reader ? "reading" : "writing"

      messages = []
      if other_only.any?
        messages << "#{list(other_only)} only #{other_only.size == 1 ? 'applies' : 'apply'} when " \
                    "#{type == :reader ? 'writing' : 'reading'} a #{name.inspect} stream and cannot be used when " \
                    "#{direction}. Configure a separate path or stream without #{other_only.size == 1 ? 'it' : 'them'} " \
                    "for #{direction}."
      end
      if invalid.any?
        messages << "Unknown #{invalid.size == 1 ? 'option' : 'options'} #{list(invalid)} when #{direction} " \
                    "a #{name.inspect} stream. Valid options: #{list(valid)}."
      end
      messages.join(" ")
    end

    def list(names)
      names.empty? ? "none" : names.map(&:inspect).join(", ")
    end

    def other_type(type)
      type == :reader ? :writer : :reader
    end

    def stream_class(type)
      case type
      when :reader
        reader_class
      when :writer
        writer_class
      else
        raise(ArgumentError, "Invalid type: #{type.inspect}. Valid types: :reader, :writer.")
      end
    end
  end
end
