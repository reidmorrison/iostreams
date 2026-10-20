module IOStreams
  class Tabular
    module Parser
      # Parsing and rendering fixed length data
      class Fixed < Base
        attr_reader :layout, :truncate

        # Returns [IOStreams::Tabular::Parser::FixedFields] the parser of the lines of a fixed width file whose schema
        # gives the position of each field, in place of the layout of this parser, see
        # `IOStreams::Tabular::Parser::Base.schema_parser`.
        def self.schema_parser(schema)
          FixedFields.new(schema)
        end

        # Returns [Hash] the schema of the layout of a fixed width file, supplied with `IOStreams::Stream#format_options`,
        # so that an application that holds a layout can replace it with its schema, see `IOStreams::Schema.from_layout`.
        # The layout itself is still read and written by this parser, as before.
        #
        # Its `fieldsMatch` is "subset", so that writing skips the keys of a record that the layout does not have, as a
        # layout always did. A line that is read always has every field.
        #
        # Parameters:
        #   layout: [Array<Hash>]
        #     Each column of the file, in order, a Hash whose keys are Symbols or Strings:
        #       size:     [Integer|:remainder] The number of characters of the column, or `:remainder` to take the
        #                 rest of the line, for the last column only. Required.
        #       key:      [String|Symbol] The key of the column in each record, which must be its own. A column without
        #                 a key is a filler, which is skipped when reading and is spaces when writing.
        #       type:     [:string|:integer|:float] Default: :string
        #       decimals: [Integer] The number of decimals of a :float column, 0 or more. A float that takes the
        #                 remainder of the line is written with the digits that it has, as the layout writes it, so
        #                 it ignores them. Default: 2
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
            column = layout_properties(column)
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

        # Returns [Hash] the properties of a column of a layout with Symbol keys, so that a layout read from JSON or
        # YAML, whose keys are Strings, such as `{"size" => 5, "key" => "zip"}`, is the same layout.
        #
        # Raises `IOStreams::Errors::InvalidLayout` when the column has a property both as a String and as a Symbol,
        # since either could be meant.
        def self.layout_properties(column)
          properties = column.transform_keys { |name| name.is_a?(String) ? name.to_sym : name }
          return properties if properties.size == column.size

          raise(Errors::InvalidLayout, "A column of the layout has a property both as a String and as a Symbol: " \
                                       "#{column.inspect}")
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
        private_class_method :layout_properties, :layout_field, :layout_column, :layout_decimals, :check_key

        # Returns [IOStreams::Tabular::Parser]
        #
        # Parameters:
        #   layout: [Array<Hash>]
        #     [
        #       {size: 23, key: "name"},
        #       {size: 40, key: "address"},
        #       {size:  2},
        #       {size:  5, key: "zip"},
        #       {size:  8, key: "age", type: :integer},
        #       {size: 10, key: "weight", type: :float, decimals: 2}
        #     ]
        #
        # Notes:
        # * Leave out the name of the key to ignore that column during parsing,
        #   and to space fill when rendering. For example as a filler.
        #
        # Types:
        #    :string
        #      This is the default type.
        #      Applies space padding and the value is left justified.
        #      Returns value as a String
        #    :integer
        #      Applies zero padding to the left.
        #      Returns value as an Integer
        #      Raises Errors::ValueTooLong when the supplied value cannot be rendered in `size` characters.
        #    :float
        #      Applies zero padding to the left.
        #      Returns value as a float.
        #      The :size is the total size of this field including the `.` and the decimals.
        #      Number of :decimals
        #      Raises Errors::ValueTooLong when the supplied value cannot be rendered in `size` characters.
        #
        # In some circumstances the length of the last column is variable.
        #   layout: [Array<Hash>]
        #     [
        #       {size: 23, key: "name"},
        #       {size: :remainder, key: "rest"}
        #     ]
        # By setting a size of `:remainder` it will take the rest of the line as the value for that column.
        #
        # A size of `:remainder` and no `:key` will discard the remainder of the line without validating the length.
        #   layout: [Array<Hash>]
        #     [
        #       {size: 23, key: "name"},
        #       {size: :remainder}
        #     ]
        #
        def initialize(layout:, truncate: true)
          @layout   = Layout.new(layout)
          @truncate = truncate
        end

        # The required line length for every fixed length line
        def line_length
          layout.length
        end

        # Returns [String] fixed layout values extracted from the supplied hash.
        #
        # Notes:
        # * A nil value is considered an empty string
        # * When a supplied value exceeds the column size it is truncated.
        def render(row, header)
          hash = header.to_hash(row)

          result = +""
          layout.columns.each do |column|
            result << column.render(hash[column.key], truncate)
          end
          result
        end

        # Returns [Hash<Symbol, String>] fixed layout values extracted from the supplied line.
        # String will be encoded to `encoding`
        def parse(line)
          unless line.is_a?(String)
            raise(Errors::TypeMismatch, "Line must be a String when format is :fixed. Actual: #{line.class.name}")
          end

          if layout.length.positive? && (line.length != layout.length)
            raise(Errors::InvalidLineLength, "Expected line length: #{layout.length}, actual line length: #{line.length}")
          end

          hash  = {}
          index = 0
          layout.columns.each do |column|
            if column.size == -1
              hash[column.key] = column.parse(line[index..]) if column.key
              break
            end

            # Ignore "columns" that have no keys. E.g. Fillers
            hash[column.key] = column.parse(line[index, column.size]) if column.key
            index += column.size
          end
          hash
        end

        # The header is required as an argument and cannot be supplied in the file itself.
        def requires_header?
          false
        end

        class Layout
          attr_reader :columns, :length

          # Returns [Array<FixedLayout>] the layout for this fixed width file.
          # Also validates values
          def initialize(layout)
            @length  = 0
            @columns = parse_layout(layout)
          end

          private

          def parse_layout(layout)
            @length = 0
            layout.collect do |hash|
              raise(Errors::InvalidLayout, "Missing required :size in: #{hash.inspect}") unless hash.key?(:size)

              column = Column.new(**hash)
              if column.size == -1
                if @length == -1
                  raise(Errors::InvalidLayout, "Only the last :size can be '-1' or :remainder in: #{hash.inspect}")
                end

                @length = -1
              else
                @length += column.size
              end
              column
            end
          end
        end

        class Column
          TYPES = %i[string integer float].freeze
          LINE_BREAK = /\r\n|\r|\n/

          attr_reader :key, :size, :type, :decimals

          def initialize(size:, key: nil, type: :string, decimals: 2)
            @key      = key
            @size     = [:remainder, "remainder"].include?(size) ? -1 : size.to_i
            @type     = type.to_sym
            @decimals = decimals

            unless @size.positive? || (@size == -1)
              raise(Errors::InvalidLayout, "Size #{size.inspect} must be positive or :remainder")
            end
            raise(Errors::InvalidLayout, "Unknown type: #{type.inspect}") unless TYPES.include?(@type)
          end

          def parse(value)
            return if value.nil?

            stripped_value = value.to_s.strip

            case type
            when :string
              stripped_value
            when :integer
              stripped_value.empty? ? nil : value.to_i
            when :float
              stripped_value.empty? ? nil : value.to_f
            else
              raise(Errors::InvalidLayout, "Unsupported type: #{type.inspect}")
            end
          end

          def render(value, truncate)
            formatted =
              case type
              when :string
                # Replace line breaks with a space so that a value cannot add records.
                value = value.to_s.gsub(LINE_BREAK, " ")
                return value if size == -1

                format(truncate ? "%-#{size}.#{size}s" : "%-#{size}s", value)
              when :integer
                return value.to_i.to_s if size == -1

                truncate = false
                format("%0#{size}d", value.to_i)
              when :float
                return value.to_f.to_s if size == -1

                truncate = false
                format("%0#{size}.#{decimals}f", value.to_f)
              else
                raise(Errors::InvalidLayout, "Unsupported type: #{type.inspect}")
              end

            if !truncate && formatted.length > size
              raise(Errors::ValueTooLong, "Value: #{value} is too large to fit into column:#{key} of size:#{size}")
            end

            formatted
          end
        end
      end
    end
  end
end
