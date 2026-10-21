# frozen_string_literal: true

module IOStreams
  module Row
    # A stream whose source is rows that were already read, rather than the bytes of a file, such as the rows of a slice,
    # see `IOStreams::Slice::Stream`, or of an Active Record query, see `IOStreams::Query::Stream`, so that they are read
    # as the rows of a file are, by the settings of the stream, such as #schema, in the format of the rows, see
    # #text_format.
    #
    # Its rows are already split and decoded, so it raises ArgumentError for what only applies to bytes: the `:stream`
    # and `:line` modes, the streams and options of #stream and #option, an encoding, #raw, and the options of lines,
    # such as `delimiter:`. Its rows are only read, so #writer, #write and #copy_from raise too.
    #
    # Each subclass names its source, see #source_name, and supplies its rows, see #rows.
    class Stream < IOStreams::Stream
      # Yields the reader of the rows in the supplied mode, see `IOStreams::Stream#reader`: `:array`, `:hash`, or
      # `:slice`, which reads them in slices.
      #
      # Raises ArgumentError for the `:stream` and `:line` modes, since the source holds rows rather than bytes or lines:
      # its rows are already split, and its header row is not a line. Raises ArgumentError for the options of lines,
      # `delimiter:`, `embedded_within:` and `buffer_size:`, before the rows are opened, or the tabular that reads them is
      # built, which describes the columns of a query, since the rows are already split.
      def reader(mode = :stream, **args, &)
        if %i[stream line].include?(mode)
          message = "A #{source_name} is read in the :array, :hash or :slice mode, not #{mode.inspect}, since it holds " \
                    "rows rather than bytes or lines"
          message = "#{message}: #{rows_hint}" if rows_hint
          raise(ArgumentError, message)
        end
        reject_lines!(**args)

        super
      end

      # Raises ArgumentError, since the rows are only read.
      def writer(*, **)
        raise(ArgumentError, read_only)
      end

      # Raises ArgumentError, since the rows are only read, before the source is opened.
      def copy_from(*, **)
        raise(ArgumentError, read_only)
      end

      # Returns [nil] without arguments, since no encoding is set, see `IOStreams::Stream#encoding`.
      #
      # Raises ArgumentError when an encoding, or another option of the encode stream, is supplied, since the rows are
      # text that was already decoded.
      def encoding(encoding = nil, **options)
        return super if encoding.nil? && options.empty?

        reject_bytes!("An encoding")
      end

      # Raises ArgumentError, since the source holds rows rather than the data of a file as it is stored.
      def raw
        reject_bytes!("#raw")
      end

      # Raises ArgumentError, since the source has no streams.
      def remove_from_pipeline(_stream_name)
        reject_bytes!("#remove_from_pipeline")
      end

      # Sets the tabular format of the rows, when the source does not decide it, see #text_format, such as a slice turned
      # back from a Hash without a format, see `IOStreams.slice`, see `IOStreams::Stream#format=`.
      #
      # Raises ArgumentError for a format other than the one that the source decides, since its rows are in that format.
      def format=(format)
        name = format.is_a?(::String) ? format.to_sym : format
        unless text_format.nil? || name.nil? || name == text_format
          raise(ArgumentError, "The rows of the #{source_name} are #{text_format.inspect}, so its format cannot be " \
                               "#{format.inspect}")
        end

        super
      end

      private

      # Returns [String] what the source is, such as "slice", which the messages of the exceptions name.
      def source_name
        raise(NotImplementedError, "#{self.class.name} must implement #source_name")
      end

      # Returns [#each] the rows that the readers of rows and records read, starting with their header row, which they
      # read as the header row of a file, see `IOStreams::Tabular#read_header`.
      def rows
        raise(NotImplementedError, "#{self.class.name} must implement #rows")
      end

      # Returns [String|nil] how to read the rows as they are, which the message of the `:stream` and `:line` modes
      # suggests, or nil when there is no such way.
      def rows_hint
        nil
      end

      # Returns [String] why the rows cannot be written.
      def read_only
        "A #{source_name} is only read: write its rows or records to a path or stream, such as with " \
          "`copy_to(path, mode: :hash)`"
      end

      # Raises ArgumentError for the streams and options of #stream, #option and #option_or_stream, including the
      # options of the rows of a format whose rows are not lines, such as Parquet, since the rows were already read.
      def merge_options(_stream, _options)
        reject_bytes!("The streams and options of #stream and #option")
      end

      # Yields [#each] the rows, see #rows. A header row that was already parsed is read as it is, see
      # `IOStreams::Tabular::Parser::Base`. The options of lines were rejected by #reader.
      def open_rows_reader(_tabular, _delimiter, _embedded_within, _buffer_size)
        yield rows
      end

      # Raises ArgumentError for the options of lines of a call that reads the rows, `delimiter:`, `embedded_within:` and
      # `buffer_size:`, since the rows are already split. The other options are checked by the reader of the mode, see
      # `IOStreams::Stream#reader`.
      def reject_lines!(delimiter: nil, embedded_within: :auto, buffer_size: nil, **)
        options = {delimiter: delimiter, embedded_within: (embedded_within unless embedded_within == :auto),
                   buffer_size: buffer_size}
        names   = options.compact.keys
        return if names.empty?

        raise(ArgumentError, "#{names.map { |name| "#{name}:" }.join(', ')} cannot be used to read a #{source_name}, " \
                             "whose rows are already split")
      end

      # Raises ArgumentError for what only applies to the bytes of a file, which the source does not have.
      def reject_bytes!(what)
        raise(ArgumentError, "#{what} cannot be used with a #{source_name}, which holds rows rather than bytes")
      end
    end
  end
end
