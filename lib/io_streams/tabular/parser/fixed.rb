module IOStreams
  class Tabular
    module Parser
      # Parsing and rendering fixed length data
      class Fixed < Base
        attr_reader :layout, :truncate

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

          result = ""
          layout.columns.each do |column|
            value = hash[column.key].to_s
            if !truncate && (value.length > column.size)
              raise(Errors::ValueTooLong, "Value: #{value.inspect} is too long to fit into column #{column.key} of size #{column.size}")
            end

            result << column.render(value)
          end
          result
        end

        # Returns [Hash<Symbol, String>] fixed layout values extracted from the supplied line.
        # String will be encoded to `encoding`
        def parse(line)
          unless line.is_a?(String)
            raise(Errors::TypeMismatch, "Line must be a String when format is :fixed. Actual: #{line.class.name}")
          end

          if line.length != layout.length
            raise(Errors::InvalidLineLength, "Expected line length: #{layout.length}, actual line length: #{line.length}")
          end

          hash  = {}
          index = 0
          layout.columns.each do |column|
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

        private

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
              @length += column.size
              column
            end
          end
        end

        class Column
          TYPES = %i[string integer float].freeze

          attr_reader :key, :size, :type, :decimals

          def initialize(key: nil, size:, type: :string, decimals: 2)
            @key      = key
            @size     = size.to_i
            @type     = type.to_sym
            @decimals = decimals

            raise(Errors::InvalidLayout, "Size #{size.inspect} must be positive") unless @size.positive?
            raise(Errors::InvalidLayout, "Unknown type: #{type.inspect}") unless TYPES.include?(type)
          end

          def parse(value)
            return if value.nil?

            stripped_value = value.to_s.strip

            case type
            when :string
              stripped_value
            when :integer
              stripped_value.length.zero? ? nil : value.to_i
            when :float
              stripped_value.length.zero? ? nil : value.to_f
            else
              raise(Errors::InvalidLayout, "Unsupported type: #{type.inspect}")
            end
          end

          def render(value)
            case type
            when :string
              format("%-#{size}.#{size}s", value.to_s)
            when :integer
              formatted = format("%0#{size}d", value.to_i)
              if formatted.length > size
                raise(Errors::ValueTooLong, "Value: #{value} is too large to fit into column:#{key} of size:#{size}")
              end

              formatted
            when :float
              formatted = format("%0#{size}.#{decimals}f", value.to_f)
              if formatted.length > size
                raise(Errors::ValueTooLong, "Value: #{value} is too large to fit into column:#{key} of size:#{size}")
              end

              formatted
            else
              raise(Errors::InvalidLayout, "Unsupported type: #{type.inspect}")
            end
          end
        end
      end
    end
  end
end
