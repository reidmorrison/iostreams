# frozen_string_literal: true

module IOStreams
  class Slice
    # Reads the rows of a file a slice at a time, see `IOStreams::Slice`, for `IOStreams::Stream#each(:slice)` and
    # `#reader(:slice)`, which create it with the rows of the file and the tabular of the stream.
    #
    # The header row, after any blank lines before it, is read by the tabular, which matches it to the fields of the
    # schema, and raises `IOStreams::Errors::InvalidHeader` when they do not match, before the first slice is yielded,
    # see `IOStreams::Tabular#read_header`. It is not a row of any slice: each slice carries it instead, see
    # `IOStreams::Slice#header`.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads slices, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Line::Reader.option_names`, the number of rows
      # of each slice, and whether to parse each row, see #initialize.
      #
      # The column options of the tabular, such as `columns:` and `allowed_columns:`, see
      # `IOStreams::Tabular.read_option_names`, are not among them: they are deprecated, and the header row that they
      # cleanse could not be read again where a slice is parsed. A schema describes the columns instead.
      def self.option_names
        [*IOStreams::Line::Reader.option_names, :size, :validate]
      end

      # Returns [Array<Symbol>] the options of .option_names that are deprecated, which a call still accepts: those of the
      # lines, see `IOStreams::Line::Reader.deprecated_option_names`, and `embedded_within`, since the format of the file
      # splits the lines of its rows, as for rows and records, see `IOStreams::Row::Reader.deprecated_option_names`.
      def self.deprecated_option_names
        [*IOStreams::Line::Reader.deprecated_option_names, :embedded_within]
      end

      # Returns [Array<String>] the header row of the file, as it was read, once it has been read, which every slice
      # carries, see `IOStreams::Slice#header`, including when the file has no rows after it, so that no slice is
      # yielded.
      # Returns nil until then, or when the file has no header row.
      attr_reader :header

      # Parameters
      #   rows: [#each]
      #     Yields each row of the file, as the format holds it: a line of text, or for a format whose rows are not
      #     lines, such as Parquet, the row that its reader returns, see `IOStreams::Tabular#read_rows`.
      #
      #   tabular: [IOStreams::Tabular]
      #     Reads the header row, and parses each row when `validate` is true.
      #
      #   size: [Integer]
      #     The number of rows of each slice, apart from the last, which holds the rows that are left.
      #
      #   validate: [true|false]
      #     Whether to parse each row before it is added to its slice, so that a row that the format or the schema
      #     cannot read, such as a value that is not of the type of its field, raises before the slice that holds it
      #     is yielded, see `IOStreams::Tabular#record_parse`. The slice still holds the row as it is in the file.
      #     Default: false
      def initialize(rows, tabular:, size:, validate: false)
        unless size.is_a?(Integer) && size.positive?
          raise(ArgumentError, "Invalid size #{size.inspect}: supply the number of rows of each slice")
        end
        unless [true, false].include?(validate)
          raise(ArgumentError, "Invalid validate #{validate.inspect}: supply true or false")
        end
        raise(ArgumentError, "Rows must be a IOStreams::Line::Reader or implement #each") unless rows.respond_to?(:each)

        @rows     = rows
        @tabular  = tabular
        @size     = size
        @validate = validate
        @header   = nil
      end

      # Yields each slice of the rows of the file, see `IOStreams::Slice`, after reading its header row, when it has one.
      # Each slice carries the line of the file that its first row is on, and the format of its rows.
      #
      # With `validate`, a row whose values are not valid raises with the line of the file that it is on, see
      # `IOStreams::Errors::Error#line_number`.
      #
      # Returns [Integer] the number of rows read, in every slice: not the header row, nor the blank lines before it.
      def each
        count = 0
        slice = nil
        line  = 0
        @rows.each do |row|
          first = line + 1
          # The line that the row ends on: a quoted line break makes a row span more than one line of the file.
          line = @rows.respond_to?(:line_number) ? @rows.line_number : first
          if @tabular.header?
            read_header(row)
            next
          end

          validate(row, first) if @validate
          slice ||= Slice.new(header: @header, line_number: first, format: @tabular.format)
          slice << row
          count += 1
          next if slice.size < @size

          yield slice
          slice = nil
        end
        yield slice if slice
        count
      end

      # Returns [String] the class, the format of the rows and the size of the slices, rather than every instance
      # variable, such as the tabular and the rows that it reads, so that irb, which displays what a reader block
      # returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect} size=#{@size}>"
      end

      private

      # Reads the header row of the row, unless the row is blank, which is skipped, see `IOStreams::Tabular#read_header`,
      # and keeps it for the slices, frozen, since they share it.
      def read_header(row)
        @tabular.read_header(row)
        @header = @tabular.header_row&.dup&.freeze
      end

      # Parses the row, which raises when its values are not valid, naming the line of the file that it is on.
      def validate(row, line_number)
        @tabular.record_parse(row)
      rescue IOStreams::Errors::Error => e
        e.line_number = line_number
        raise
      end
    end
  end
end
