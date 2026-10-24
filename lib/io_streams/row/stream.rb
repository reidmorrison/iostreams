# frozen_string_literal: true

module IOStreams
  module Row
    # A stream whose source is rows that were already read, rather than the bytes of a file, such as the rows of a slice,
    # see `IOStreams::Slice::Stream`, or of an Active Record query, see `IOStreams::Query::Stream`, so that they are read
    # as the rows of a file are, by the settings of the stream, such as #schema, in the format of the rows, see
    # #text_format.
    #
    # Its rows are already split and decoded, so it raises ArgumentError for what only applies to bytes: the `:stream`
    # and `:line` modes, the streams and options of #stream and #option, an encoding, #raw, see
    # `IOStreams::Row::WithoutBytes`, and the options of lines, such as `delimiter:`. Its rows are only read, so
    # #writer, #write and #copy_from raise too.
    #
    # Each subclass names its source, see #source_name, and supplies its rows, see #rows, or opens them, when they must
    # be opened to be read, see #open_rows.
    class Stream < IOStreams::Stream
      include WithoutBytes

      # Yields the reader of the rows in the supplied mode, see `IOStreams::Stream#reader`: `:array`, `:hash`, or
      # `:slice`, which reads them in slices.
      #
      # Raises ArgumentError for the `:stream` and `:line` modes, since the source holds rows rather than bytes or lines:
      # its rows are already split, and its header row is not a line. Raises ArgumentError for the options of lines,
      # `delimiter:` and `buffer_size:`, before the rows are opened, or the tabular that reads them is
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

      # Returns [#each] the rows that the readers of rows and records read, starting with their header row, which they
      # read as the header row of a file, see `IOStreams::Tabular#read_header`, see #open_rows.
      def rows
        raise(NotImplementedError, "#{self.class.name} must implement #rows or #open_rows")
      end

      # Yields [#each] the rows that the readers of rows and records read, which the tabular reads, see #rows. A source
      # whose rows must be opened before they are read opens them instead, so that its reader is yielded only once they
      # can be read, such as a query, see `IOStreams::Query::Stream#open_rows`.
      #
      # Returns the result of the block.
      def open_rows(_tabular)
        yield rows
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

      # Yields [#each] the rows, see #open_rows, which the tabular reads. A header row that was already parsed is read as
      # it is, see `IOStreams::Tabular::Parser::Base`. The options of lines were rejected by #reader.
      def open_rows_reader(tabular, _delimiter, _buffer_size, &)
        open_rows(tabular, &)
      end

      # Yields [#each_with_line_number] the rows, see #open_rows, which a slice reader reads, see
      # `IOStreams::Stream#open_slice_rows`. They are not the lines of a file, so they start on no line, see
      # `IOStreams::Slice::Rows`, and the slices number each one as the next record, unless the source knows their
      # numbers, such as a slice, see `IOStreams::Slice::Stream#open_slice_rows`.
      def open_slice_rows(tabular, _delimiter, _buffer_size)
        open_rows(tabular) { |rows| yield IOStreams::Slice::Rows.new(rows) }
      end

      # Raises ArgumentError for the options of lines of a call that reads the rows, `delimiter:` and `buffer_size:`,
      # since the rows are already split. The other options are checked by the reader of the mode, see
      # `IOStreams::Stream#reader`.
      def reject_lines!(delimiter: nil, buffer_size: nil, **)
        names = {delimiter: delimiter, buffer_size: buffer_size}.compact.keys
        return if names.empty?

        raise(ArgumentError, "#{names.map { |name| "#{name}:" }.join(', ')} cannot be used to read a #{source_name}, " \
                             "whose rows are already split")
      end
    end
  end
end
