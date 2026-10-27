# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      # Parses and renders the lines of a fixed width file, where each field is at the same position in every line,
      # which the schema gives with the `width`, and optionally the `start`, of each field, see `IOStreams::Schema`.
      # Each row is the values of the fields, in their order, as for CSV, since a line has no names, so the mapping of
      # the columns names them, see `IOStreams::Tabular::SchemaMapping`.
      #
      # When reading, each value is the text at the position of its field without its leading and trailing spaces,
      # which the schema then converts to the type of its field.
      #
      # When writing, a number is right justified and zero filled, and a missing number is written as zero, as most
      # specifications of fixed width files require, except a number that is not finite, such as NaN, which is space
      # filled, so that it can be read back. Any other value is left justified and space filled, with each
      # line break replaced with a space, so that a value cannot add records. The characters that no field covers,
      # such as fillers, are spaces.
      class Fixed < Base
        DIGIT = /\d/

        # Where a field is in each line: the offset of its first character, and its width, or -1 for the remainder of
        # the line.
        Column = Struct.new(:field, :index, :width)

        # Returns [String] the encoding of fixed width files, ASCII, read as UTF-8 strings.
        #
        # The sizes of the columns in a fixed width file count bytes, since the programs that write them, such as
        # COBOL programs, and the formats that specify them, such as NACHA, count bytes. Their text is ASCII, or a
        # single-byte code page that the caller names on the encode stream, such as "ISO-8859-1:UTF-8". So any other
        # byte raises `IOStreams::Errors::InvalidEncoding` instead of misaligning the columns that follow it.
        #
        # When writing, only the external encoding, ASCII, applies, so a value that is not ASCII raises
        # `Encoding::UndefinedConversionError` instead of writing a line that is longer than its fields in bytes.
        def self.encoding
          "US-ASCII:UTF-8"
        end

        # Returns [Integer] the length of every line, or -1 when a line can be any length, after a field or a schema
        # width of "remainder", or 0 when there are no fields.
        attr_reader :line_length

        # Parameters:
        #   schema: [IOStreams::Schema]
        #     The schema, which must give the width of each field.
        #
        # Raises ArgumentError when the schema does not give the position of each field.
        def initialize(schema: nil)
          unless schema
            raise(ArgumentError, "The :fixed format needs a schema that gives the width of each field, see IOStreams::Stream#schema")
          end

          super
          @columns     = []
          @line_length = build_columns
        end

        # Returns [Array] the text of each field of the line, in the order of the fields, without its leading and
        # trailing spaces, or the row supplied, an Array that is already parsed, as it is, as CSV does, see
        # `IOStreams::Tabular#record_parse`.
        def parse(line)
          return line if line.is_a?(::Array)
          unless line.is_a?(String)
            raise(Errors::TypeMismatch, "Line must be a String when format is :fixed. Actual: #{line.class.name}")
          end

          if line_length.positive? && line.length != line_length
            raise(Errors::InvalidLineLength, "Expected line length: #{line_length}, actual line length: #{line.length}")
          end

          @columns.map do |column|
            value = column.width == -1 ? line[column.index..] : line[column.index, column.width]
            value&.strip
          end
        end

        # Returns [String] the line of the values of the fields, in the order of the fields, which the schema has already
        # rendered as text, see `IOStreams::Tabular::SchemaMapping#render`.
        def render(row)
          line = +""
          @columns.each_with_index do |column, index|
            line << (" " * (column.index - line.length)) if column.index > line.length
            line << render_value(column, row[index])
          end
          line << (" " * (line_length - line.length)) if line_length > line.length
          line
        end

        # The header is required as an argument and cannot be supplied in the file itself.
        def requires_header?
          false
        end

        private

        # Returns [Integer] the length of every line, see #line_length, once it works out where each field is.
        def build_columns
          position = 0
          @schema.fields.each do |field|
            if position == -1
              raise(ArgumentError, "Only the last field can have a width of \"remainder\", " \
                                   "but field #{field.name.inspect} follows it")
            end
            raise(ArgumentError, "Field #{field.name.inspect} needs a width for the :fixed format") if field.width.nil?

            index = field.start ? field.start - 1 : position
            if index < position
              raise(ArgumentError, "Field #{field.name.inspect} starts at #{field.start}, within the field before it, " \
                                   "which ends at #{position}")
            end

            size = field.width == :remainder ? -1 : field.width
            @columns << Column.new(field, index, size)
            position = size == -1 ? -1 : index + size
          end
          schema_line_length(position)
        end

        def schema_line_length(position)
          width = @schema.width
          return position if width.nil?
          return -1 if width == :remainder

          if position == -1
            raise(ArgumentError, "The schema width cannot be set when the last field takes the remainder of the line")
          end
          if width < position
            raise(ArgumentError, "The schema width #{width} is less than the end of the last field, at #{position}")
          end

          width
        end

        def render_value(column, text)
          field = column.field
          return render_number(column, text.nil? ? field.render(0, :text) : text.to_s) if field.numeric?

          text = text.to_s
          text = text.gsub(LINE_BREAK, " ") if LINE_BREAK.match?(text)
          return text if column.width == -1
          return text.ljust(column.width) if text.length <= column.width
          raise(value_too_long(column, text)) unless field.truncate?

          text[0, column.width]
        end

        def render_number(column, text)
          return text if column.width == -1

          padded =
            # A number that is not finite, such as NaN or -INF, has no digits to zero fill, so that it can be read back.
            if !DIGIT.match?(text)
              text.rjust(column.width)
            elsif text.start_with?("-")
              "-#{text.delete_prefix('-').rjust(column.width - 1, '0')}"
            else
              text.rjust(column.width, "0")
            end
          raise(value_too_long(column, text)) if padded.length > column.width

          padded
        end

        def value_too_long(column, text)
          message = "Value: #{text} is too large to fit into column:#{column.field.name} of size:#{column.width}"
          Errors::ValueTooLong.new(message)
        end
      end
    end
  end
end
