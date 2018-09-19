module IOStreams
  class Tabular
    module Parser
      # Parsing and rendering fixed length data
      class Fixed < Base
        attr_reader :encoding, :encoding_options, :fixed_format

        # Returns [IOStreams::Tabular::Parser]
        #
        # Arguments:
        #   format: [Array<Hash>]
        #     [
        #       {key: 'name',    size: 23 },
        #       {key: 'address', size: 40 },
        #       {key: 'zip',     size: 5 }
        #     ]
        #
        #   encoding: [String|Encoding]
        #     nil: Don't perform any encoding conversion
        #     'ASCII': ASCII Format
        #     'UTF-8': UTF-8 Format
        #     Etc.
        #     Default: nil
        #
        #   replacement: [String]
        #     The character to replace with when a character cannot be converted to the target encoding.
        #     nil: Don't replace any invalid characters. Encoding::UndefinedConversionError is raised.
        #     Default: nil
        def initialize(format:, encoding: nil, replacement: nil)
          @encoding         = encoding.nil? || encoding.is_a?(Encoding) ? encoding : Encoding.find(encoding)
          @encoding_options = replacement.nil? ? {} : {invalid: :replace, undef: :replace, replace: replacement}
          @fixed_format     = parse_format(format)
        end

        # Returns [String] fixed format values extracted from the supplied hash.
        # String will be encoded to `encoding`
        def render(row, header)
          hash = header.to_hash(row)

          result = encoding.nil? ? '' : ''.encode(encoding)
          fixed_format.each do |map|
            # A nil value is considered an empty string
            value = hash[map.key].to_s
            result <<
              if encoding
                format("%-#{map.size}.#{map.size}s".encode(encoding), value.encode(encoding, encoding_options))
              else
                format("%-#{map.size}.#{map.size}s", value)
              end
          end
          result
        end

        # Returns [Hash<Symbol, String>] fixed format values extracted from the supplied line.
        # String will be encoded to `encoding`
        def parse(line)
          unless line.is_a?(String)
            raise(Tabular::Errors::TypeMismatch, "Format is :fixed. Invalid parse input: #{line.class.name}")
          end

          hash  = {}
          index = 0
          fixed_format.each do |map|
            value         = line[index..(index + map.size - 1)]
            index         += map.size
            hash[map.key] = encoding.nil? ? value.strip : value.strip.encode(encoding, encoding_options)
          end
          hash
        end

        private

        FixedFormat = Struct.new(:key, :size)

        # Returns [Array<FixedFormat>] the format for this fixed width file.
        # Also validates values
        def parse_format(format)
          format.collect do |map|
            size = map[:size]
            key  = map[:key]
            raise(ArgumentError, "Missing required :key and :size in: #{map.inspect}") unless size && key
            FixedFormat.new(key, size)
          end
        end
      end
    end
  end
end
