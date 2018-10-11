module IOStreams
  class Tabular
    module Parser
      # Parsing and rendering fixed length data
      class Fixed < Base
        attr_reader :fixed_layout

        # Returns [IOStreams::Tabular::Parser]
        #
        # Parameters:
        #   layout: [Array<Hash>]
        #     [
        #       {key: 'name',    size: 23 },
        #       {key: 'address', size: 40 },
        #       {key: 'zip',     size: 5 }
        #     ]
        def initialize(layout:)
          @fixed_layout = parse_layout(layout)
        end

        # Returns [String] fixed layout values extracted from the supplied hash.
        # String will be encoded to `encoding`
        def render(row, header)
          hash = header.to_hash(row)

          result = ''
          fixed_layout.each do |map|
            # A nil value is considered an empty string
            value = hash[map.key].to_s
            result << format("%-#{map.size}.#{map.size}s", value)
          end
          result
        end

        # Returns [Hash<Symbol, String>] fixed layout values extracted from the supplied line.
        # String will be encoded to `encoding`
        def parse(line)
          unless line.is_a?(String)
            raise(IOStreams::Errors::TypeMismatch, "Format is :fixed. Invalid parse input: #{line.class.name}")
          end

          hash  = {}
          index = 0
          fixed_layout.each do |map|
            value         = line[index..(index + map.size - 1)]
            index         += map.size
            hash[map.key] = value.to_s.strip
          end
          hash
        end

        private

        FixedLayout = Struct.new(:key, :size)

        # Returns [Array<FixedLayout>] the layout for this fixed width file.
        # Also validates values
        def parse_layout(layout)
          layout.collect do |map|
            size = map[:size]
            key  = map[:key]
            raise(ArgumentError, "Missing required :key and :size in: #{map.inspect}") unless size && key
            FixedLayout.new(key, size)
          end
        end
      end
    end
  end
end
