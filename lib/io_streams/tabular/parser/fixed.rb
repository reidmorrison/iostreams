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
        LINE_BREAK = /\r\n|\r|\n/
        DIGIT      = /\d/

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
        # `Encoding::UndefinedConversionError` instead of writing a line that is longer than the layout in bytes.
        def self.encoding
          "US-ASCII:UTF-8"
        end

        # Returns [Hash] the schema of the layout of a fixed width file, supplied with `IOStreams::Stream#format_options`,
        # which is deprecated, so that the schema reads and writes the file instead, see `IOStreams::Schema`.
        #
        # Its `fieldsMatch` is "subset", so that writing skips the keys of a record that the layout does not have, as a
        # layout always did. A line that is read always has every field.
        #
        # Parameters:
        #   layout: [Array<Hash>]
        #     Each column of the file, in order:
        #       size:     [Integer|:remainder] The number of characters of the column, or `:remainder` to take the
        #                 rest of the line, for the last column only. Required.
        #       key:      [String|Symbol] The key of the column in each record, which must be its own. A column without
        #                 a key is a filler, which is skipped when reading and is spaces when writing.
        #       type:     [:string|:integer|:float] Default: :string
        #       decimals: [Integer] The number of decimals of a :float column, 0 or more. A float that takes the
        #                 remainder of the line is written with the digits that it has, as before the layout was
        #                 deprecated, so it ignores them. Default: 2
        #
        #   truncate: [true|false]
        #     Whether to truncate a string that is longer than its column, rather than raise
        #     `IOStreams::Errors::ValueTooLong`.
        #     Default: true
        #
        # Raises `IOStreams::Errors::InvalidLayout` when the layout is not valid, including when its schema could not
        # hold it, such as for two columns with the same key, which the records read could not hold either.
        def self.schema(layout:, truncate: true)
          raise(Errors::InvalidLayout, "The layout must be an Array of columns: #{layout.inspect}") unless layout.is_a?(::Array)

          fields   = []
          keys     = {}
          position = 1
          last     = nil
          layout.each do |column|
            unless column.is_a?(::Hash)
              raise(Errors::InvalidLayout, "Each column of the layout must be a Hash, such as {size: 10, key: :name}: " \
                                           "#{column.inspect}")
            end
            raise(Errors::InvalidLayout, "Missing required :size in: #{column.inspect}") unless column.key?(:size)
            raise(Errors::InvalidLayout, "Only the last :size can be '-1' or :remainder in: #{column.inspect}") if last == -1

            # A column after a filler starts after the filler.
            filler      = last && fields.last.nil?
            size, field = layout_field(column, filler ? position : nil, truncate)
            check_key(field[:name], keys) if field
            fields << field
            last = size
            position += size unless size == -1
          end

          schema = {fields: fields.compact, fieldsMatch: "subset"}
          # A filler at the end of the line gives the width of the line.
          schema[:width] = last == -1 ? "remainder" : position - 1 if last && fields.last.nil?
          schema
        end

        # Returns [Array(Integer, Hash)] the size of a column of a layout, see .schema, and the field of the schema for
        # it, or nil for a filler.
        def self.layout_field(column, start, truncate)
          size, key, type, decimals = layout_column(**column)
          width = [:remainder, "remainder"].include?(size) ? -1 : size.to_i
          unless width.positive? || width == -1
            raise(Errors::InvalidLayout, "Size #{size.inspect} must be positive or :remainder")
          end
          unless type.respond_to?(:to_sym) && %i[string integer float].include?(type.to_sym)
            raise(Errors::InvalidLayout, "Unknown type: #{type.inspect}")
          end
          return [width, nil] unless key

          unless key.is_a?(String) || key.is_a?(Symbol)
            raise(Errors::InvalidLayout, "The key of a column of the layout must be a String or a Symbol, such as " \
                                         "#{key.to_s.inspect}, or none for a filler: #{key.inspect}")
          end

          field = {name: key, type: {string: "string", integer: "integer", float: "number"}[type.to_sym]}
          field[:width] = width == -1 ? "remainder" : width
          field[:start] = start if start
          case type.to_sym
          when :string then field[:truncate] = true if truncate
          when :float
            field[:floatNumber] = true
            # The layout wrote a float that takes the remainder of the line with the digits that it has.
            field[:decimals] = layout_decimals(key, decimals) unless width == -1
          end
          [width, field]
        end

        # Returns [Array] the properties of a column of a layout, raising ArgumentError for any other.
        def self.layout_column(size:, key: nil, type: :string, decimals: 2)
          [size, key, type, decimals]
        end

        # Returns [Integer] the decimals of a :float column of a layout, see .schema.
        def self.layout_decimals(key, decimals)
          digits = decimals.to_i
          return digits unless digits.negative?

          raise(Errors::InvalidLayout, "The decimals of the column #{key.inspect} of the layout must be 0 or more: " \
                                       "#{decimals.inspect}")
        end

        # Raises `IOStreams::Errors::InvalidLayout` when another column of the layout has the same key as text, see
        # .schema, since the key of each column is its key in each record, and the name of its field. Adds the key to
        # the keys of the columns before it, by their text.
        def self.check_key(key, keys)
          other = keys[key.to_s]
          keys[key.to_s] = key
          return if other.nil?

          subject =
            if other.eql?(key)
              "More than one column of the layout has the key #{key.inspect}"
            else
              "The columns of the layout with the keys #{other.inspect} and #{key.inspect} have the same key"
            end
          raise(Errors::InvalidLayout, "#{subject}, but each column needs a key of its own, its key in each record. A " \
                                       "column without a key is a filler, which is skipped when reading and written as " \
                                       "spaces, so remove the key of a filler.")
        end
        private_class_method :layout_field, :layout_column, :layout_decimals, :check_key

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
