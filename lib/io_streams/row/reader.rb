# frozen_string_literal: true

module IOStreams
  module Row
    # Converts each line of an input stream into an array for every line, for `IOStreams::Stream#each(:array)` and
    # `#reader(:array)`, which create it with the tabular of the stream.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads rows, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Line::Reader.option_names`, and those of the
      # `IOStreams::Tabular` that parses them, see `IOStreams::Tabular.read_option_names`.
      def self.option_names
        [*IOStreams::Line::Reader.option_names, *IOStreams::Tabular.read_option_names]
      end

      # Returns [Array<Symbol>] the options of .option_names that are deprecated, which a call still accepts: those of the
      # lines, see `IOStreams::Line::Reader.deprecated_option_names`, `embedded_within`, since the format of the file splits
      # the lines of its rows, and those of the tabular, see `IOStreams::Tabular.deprecated_option_names`.
      def self.deprecated_option_names
        [*IOStreams::Line::Reader.deprecated_option_names, :embedded_within, *IOStreams::Tabular.deprecated_option_names]
      end

      # Create a reader that returns the stream rows as arrays.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, holds the header, and cleanses the header row as its `cleanse_header`
      #     option says, see `IOStreams::Tabular.new`.
      def initialize(line_reader, tabular:)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns
      end

      # Returns [true|false] whether the first row that #each yields is a header row, which names the column of each
      # value of the rows after it, so that a copy can write it as a header row, see `IOStreams::Row::Writer#write_header`:
      # the header row of the file, or the keys of the first record of a format of keyed records, such as JSON, without a
      # schema, see `IOStreams::Tabular#rows_header?`. Asked before #each.
      def header?
        @tabular.rows_header?
      end

      # Yields the header row as it was read, followed by each row, an Array, whatever the format. A file without a
      # header row, such as fixed width, or JSON with a schema, yields no header row: each row is the values of the
      # fields of the schema, or of the layout, in order. The header row of JSON without a schema is the keys of its first
      # record, and each row the values of a record in that order, see `IOStreams::Tabular#read_row`.
      #
      # The allowed and required columns are applied to the header row, or to the supplied columns,
      # even when `cleanse_header` is false, unless `IOStreams.enforce_column_restrictions?` is false.
      # Each row still contains every value.
      #
      # With a schema, the header row is the names of the fields of its columns, and each row is the values of those
      # fields, in the order of the fields, without the columns that the schema skips, see `IOStreams::Tabular#row_parse`.
      def each(&block)
        @line_reader.each { |line| @tabular.read_row(line, &block) }
      end

      # Writes each row to the writer, see `IOStreams::Row::Writer`, as a copy does, see `IOStreams::Stream#copy_from`,
      # telling it the column of each value of the rows: it writes the header row of the file as their header row, see
      # `IOStreams::Row::Writer#write_header`, so that a format without one, such as JSON, takes their columns from it,
      # rather than write it as a row of values, or, for a file without a header row whose schema gives its columns,
      # the names of the fields as their columns, see `IOStreams::Row::Writer#write_columns`, before the first row. A
      # blank line, which #each yields as nil, is not a row, so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        columns = @tabular.headerless_columns
        writer.write_columns(columns) if columns
        header = header?
        each do |row|
          next if row.nil?

          if header
            header = false
            writer.write_header(row)
          else
            writer << row
          end
        end
      end

      # Returns [String] the class and the format of the rows, see `IOStreams::Tabular#format`, rather than every instance
      # variable, such as the tabular and the lines that it reads, so that irb, which displays what a reader block
      # returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end
    end
  end
end
