module IOStreams
  class Builder
    # What v2.2 reports about the streams, options and format of a builder as deprecation warnings: those that
    # IOStreams v3.0 removes or rejects, and those whose results change in v3.0, with what to use instead. It is part
    # of the Builder, which includes it, since the Builder owns the settings that it reports on.
    module Deprecations
      # A format set with #format= that is not the format of the text that the streams read, see #text_format, such as
      # `:psv` for a spreadsheet, whose rows are read as CSV, is deprecated, since v3.0 raises ArgumentError when its
      # lines, rows or records are read, rather than read them in that format. Reports a deprecation warning when they are
      # read, as v3.0 raises then, whichever way the streams were set.
      #
      # So is reading them in the format that the file name names, such as `:psv` for `report.psv.xlsx`, without a format
      # set, since v3.0 reads them in the format of the text whatever the file name, so that `format(:csv)` reads them
      # the same in both versions.
      #
      # Neither is looked for while deprecation warnings are off, see `IOStreams::Deprecation.on?`, since finding the
      # format of the text would build the pipeline once more for each read.
      def warn_text_format
        return unless Deprecation.on?

        format = self.format
        return if format.nil?

        text_format = self.text_format
        return if text_format.nil? || format == text_format

        if @set_format
          Deprecation.warn("format(#{format.inspect}) is deprecated when the streams read the rows as " \
                           "#{text_format.inspect}, such as those of a spreadsheet, since v3.0 raises ArgumentError for " \
                           "it, set format(#{text_format.inspect}) instead, or no format")
        else
          Deprecation.warn("the format #{format.inspect} that the file name names is deprecated when the streams read " \
                           "the rows as #{text_format.inspect}, such as those of a spreadsheet, since v3.0 reads them as " \
                           "#{text_format.inspect} whatever the file name, set format(#{text_format.inspect}) to read " \
                           "them so in both versions")
        end
      end

      # An encoding set with #encoding is deprecated when the rows and records of a spreadsheet are read, see
      # `IOStreams::Stream#warn_cell_rows`, which are its cells rather than lines of text, since v3.0 raises ArgumentError
      # for it then. Its lines still take it. Without it, a schema reads the text of the cells as UTF-8, see #utf8_text?,
      # as v3.0 does.
      def warn_cells_encoding
        return if @encoding.nil?

        Deprecation.warn("#encoding is deprecated when the rows and records of a spreadsheet are read, which are its " \
                         "cells rather than lines of text, since v3.0 raises ArgumentError for it, so remove it, and " \
                         "give its columns a schema, with which v2.2 reads the text of its cells as UTF-8; " \
                         "each(:line) still takes it")
      end

      # Returns [Array(Array<Symbol>, String, Hash|nil)|nil] the methods that the stream that the application's block
      # receives in v3.0 answers, its name for a deprecation warning, such as "the :gz stream", and what replaces each
      # method that v3.0 removes, when the stream says, see `IOStreams::Reader.v3_stream_advice`, when the stream that it
      # receives in v2.2 answers others, otherwise nil. The stream closest to the application decides, with its options,
      # see `IOStreams::Reader.v3_stream_methods`. Without any streams, the block receives the IO that they would read or
      # write, which the supplied source describes, see `IOStreams::Stream#v3_source` and `IOStreams::Stream#v3_target`.
      #
      # Parameters:
      #   type: [:reader|:writer]
      #   source: [Array(Array<Symbol>, String)|nil]
      #     The methods and the name of the IO that the streams read or write in v3.0, when it differs from the one in
      #     v2.2, otherwise nil.
      #
      # Yields, only when the stream closest to the application asks and is the only stream, to ask whether the streams
      # read a regular local file in v3.0. The block answers true or false.
      #
      # Asked before the streams are opened, so it raises nothing, not even for a stream without a class of the type, which
      # raises as before once it is opened.
      def v3_stream(type, source)
        streams       = pipeline
        name, options = streams.first
        return source if name.nil?

        klass = IOStreams.extensions[name]&.public_send(:"#{type}_class")
        return unless klass.respond_to?(:v3_stream_methods)

        methods = klass.v3_stream_methods(options) { streams.size == 1 && yield }
        return unless methods

        [methods, "the #{name.inspect} stream", (klass.v3_stream_advice if klass.respond_to?(:v3_stream_advice))]
      end

      # Returns [Symbol|nil] the format that the rows and records of this file are read and written in, when IOStreams
      # v3.0 reads and writes them in its `:text` format instead, as the text of each line: when no format was set, so
      # that it is taken from a file name whose format extension is `.text`, see `IOStreams::Tabular.text_file_format`,
      # unless a stream reads the lines in a format of its own, such as the CSV of a spreadsheet, which v3.0 reads them
      # in, whatever format the file name names. Returns nil otherwise.
      def text_file_format
        return if format_set? || file_name.nil? || text_format

        Tabular.text_file_format(file_name)
      end

      private

      # Reports a deprecation warning for supplying `:none`, see #raw, or for setting the encode stream, see #encoding,
      # which names the method that the application called.
      def warn_deprecated_stream(method, stream)
        case stream
        when :none
          Deprecation.warn("#{method}(:none) is deprecated, use #raw to read or write the data as it is stored, " \
                           "or #file_name to read a file that is not named for its format")
        when :encode
          # Like any other stream set with #stream, stream(:encode, ...) stops the streams being taken from the file
          # name, which #encoding keeps.
          if method == "stream"
            Deprecation.warn("stream(:encode, ...) is deprecated, use #encoding instead, which keeps the streams that " \
                             "the file name implies, #raw to read or write the data as it is stored, or #file_name to " \
                             "read a file that is not named for its format")
          else
            Deprecation.warn("#{method}(:encode, ...) is deprecated, use #encoding instead")
          end
        end
      end

      # Reports a deprecation warning for each option of the stream that IOStreams 3.0 raises ArgumentError for when it is
      # set with #option, #stream or #option_or_stream, whether or not the file name includes the stream, so that it is
      # reported wherever the code runs, rather than only where a file name includes the stream: one that the reader or
      # the writer of the stream replaces, with the option that replaces it, see
      # `IOStreams::Deprecation::OptionNames#replaced_option_names`, and one that neither of them takes in IOStreams 3.0,
      # such as a misspelled one, see #v3_option_names. An option of the other direction is not reported, since v3.0
      # accepts it, and ignores it, nor are the options of the encode stream, which is deprecated itself, see
      # #warn_deprecated_stream, or of `:none`, which takes none.
      def warn_deprecated_options(stream, options)
        return if options.empty? || %i[encode none].include?(stream)

        classes  = v3_stream_classes(stream)
        replaced = classes.each_with_object({}) do |klass, names|
          names.merge!(klass.replaced_option_names) if klass.respond_to?(:replaced_option_names)
        end.slice(*options.keys)
        replaced.each_pair { |name, replacement| Deprecation.warn("#{name}: is deprecated, use #{replacement}: instead") }

        known = v3_option_names(classes)
        names = known ? options.keys - replaced.keys - known : []
        return if names.empty?

        words = Deprecation::Words.new(names)
        Deprecation.warn("#{words.keywords} #{words.are} deprecated for a #{stream.inspect} stream, since neither its " \
                         "reader nor its writer takes #{words.them}, so correct or remove #{words.them}")
      end

      # Returns [Array<Class|Module>] the classes that read and write the stream in IOStreams 3.0, as far as they are
      # known: the reader and the writer registered for it, and, in place of a writer that it does not have, the stand-in
      # for the one that IOStreams 3.0 adds, when its reader names one, such as for `.xlsx`, see
      # `IOStreams::Xlsx::Reader.v3_writer`. None when the stream is not registered.
      def v3_stream_classes(stream)
        extension = IOStreams.extensions[stream]
        return [] unless extension

        reader   = extension.reader_class
        writer   = extension.writer_class
        writer ||= reader.v3_writer if reader.respond_to?(:v3_writer)
        [reader, writer].compact
      end

      # Returns [Array<Symbol>|nil] the options that IOStreams 3.0 accepts when they are set for a stream of the supplied
      # classes, see #v3_stream_classes: those that its reader or its writer takes, or nil when they are not known, since
      # a class does not declare them, as one that an application registers need not.
      def v3_option_names(classes)
        names = classes.map { |klass| v3_class_option_names(klass) }
        names.flatten.uniq unless names.empty? || names.include?(nil)
      end

      # Returns [Array<Symbol>|nil] the options that the class takes in IOStreams 3.0, see
      # `IOStreams::Deprecation::OptionNames#known_option_names`, or those that it declares when it does not answer them,
      # as a class that an application registers need not, or nil when it does neither.
      def v3_class_option_names(klass)
        return klass.known_option_names if klass.respond_to?(:known_option_names)

        klass.option_names if klass.respond_to?(:option_names)
      end

      # Reports a deprecation warning, when the streams are opened, for those that are deprecated, or whose results
      # change in IOStreams v3.0.
      def warn_deprecated_streams
        warn_encode_extension
        warn_temp_file_streams
        warn_extension_options
      end

      # A file name ending in `.encode` is deprecated, since file names do not name the encode stream, see #encoding.
      # Once the encode stream is set, with #encoding or `option(:encode, ...)`, the file name adds nothing to it, so it
      # is only reported when the file name is what applies the encode stream.
      def warn_encode_extension
        return if streams || @encoding || options&.key?(:encode)
        return if file_name.nil? || !parse_extensions.include?(:encode)

        Deprecation.warn("a file name ending in .encode is deprecated, since file names do not name the encode " \
                         "stream, use #encoding instead")
      end

      # The path of `IOStreams.temp_file` reads and writes its data as it is stored, see #no_streams, while IOStreams v3.0
      # applies the streams that its file name implies, so reading or writing it is deprecated while it has no streams of
      # its own, and its file name implies some, other than `.encode`, which v3.0 no longer applies, see #raw, which reads
      # and writes the data as it is stored on both.
      def warn_temp_file_streams
        return unless @temp_file && streams.empty? && file_name
        return if (parse_extensions - [:encode]).empty?

        Deprecation.warn("reading or writing the path of IOStreams.temp_file is deprecated when its extension names " \
                         "streams, such as .gz, since v3.0 applies them, where v2.2 reads and writes the data as it is " \
                         "stored: call #raw on the path to read and write the data as it is stored")
      end

      # The options set for another extension of the format of an extension in the file name, such as
      # `option(:pgp, ...)` for a `.gpg` file, are ignored, while IOStreams v3.0 applies the options of a format to each of
      # its extensions, and then those set for the extension in the file name, which take precedence. So they are
      # deprecated unless those of the extension itself set each of them too, with which both apply the same options.
      def warn_extension_options
        return if streams || options.nil? || file_name.nil?

        parse_extensions.each do |stream|
          own = options[stream] || {}
          options.each_pair do |name, opts|
            next if name == stream || (opts.keys - own.keys).empty? || !same_format?(name, stream)

            Deprecation.warn("option(:#{name}, ...) is deprecated for a file name with the extension .#{stream}, which " \
                             "v2.2 does not apply it to, since v3.0 applies the options of a format to each of its " \
                             "extensions: set them with option(:#{stream}, ...)")
          end
        end
      end

      # Returns [true|false] whether the extensions are of the same format, whose reader and writer they share, such as
      # `.pgp` and `.gpg`, or `.gz` and `.gzip`.
      def same_format?(extension, other)
        registered = IOStreams.extensions[extension]
        other      = IOStreams.extensions[other]
        return false if registered.nil? || other.nil?

        registered.reader_class == other.reader_class && registered.writer_class == other.writer_class
      end
    end
  end
end
