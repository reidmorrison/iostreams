# frozen_string_literal: true

require "json"
module IOStreams
  class Tabular
    module Parser
      # For parsing a single line of JSON at a time
      class Json < Base
        # Returns [:json] JSON writes numbers and booleans as themselves, and every other value as text.
        def self.value_form
          :json
        end

        # Returns [true] each line is a JSON object, whose keys name its values.
        def self.keyed?
          true
        end

        # Returns [true] each record supplies its own keys, and can leave out the key of a value that is missing.
        def self.keys_vary?
          true
        end

        # Returns [JSON::Coder|nil] a coder that writes a record as `.json_value(record).to_json` does, in one pass over its
        # values in the json gem, rather than one pass in Ruby, then another to write them.
        #
        # Returns nil before json 2.10, which added `JSON::Coder`, for a version whose coder does not write a key that is
        # not a String the same way, or does not hand its block the text that it does not write as it is, see .hands_text?,
        # and when another library, such as ActiveSupport, has replaced `Hash#to_json`, since the coder would not write
        # the JSON that it does.
        def self.coder
          return unless ::Hash.instance_method(:to_json).owner.name&.start_with?("JSON::")
          return @coder if defined?(@coder)

          @coder = build_coder
        end

        def self.build_coder
          return unless defined?(::JSON::Coder) && defined?(::JSON::Fragment)

          coder = ::JSON::Coder.new do |value, key|
            # Text that the json gem does not write as it is, such as binary text, which it hands to the block, see
            # .hands_text? and .json_text.
            next json_text(value) if value.is_a?(String)
            # Like `Hash#to_json`, which writes a key that is not a String with `to_s`.
            next json_text(value.to_s) if key

            json = IOStreams::Schema::Field.any_json(value)
            next ::JSON::Fragment.new(value.to_json) if json.equal?(value)

            json.is_a?(String) ? json_text(json) : json
          end
          coder if coder.dump({1 => nil}) == '{"1":null}' && hands_text?(coder)
        rescue StandardError
          nil
        end
        private_class_method :build_coder

        # Returns [true|false] whether the json gem hands the block of the coder the text that it does not write as it is,
        # such as binary text, as json 2.16 and later do on MRI, so that the block writes it as UTF-8, or raises for text
        # that is not valid, see .json_text, as the json gem writes the rest of the record. Before json 2.16, and with
        # JRuby's json 2, the json gem writes binary text itself instead, with the warning `UTF-8 string passed as
        # BINARY`, or raises `JSON::GeneratorError`, and JRuby's writes the bytes of binary text that is not valid UTF-8
        # once Ruby has scanned it, such as for `String#ascii_only?`, so IOStreams does not use such a coder, but converts
        # the text of each value before it writes it, see .generate. Text that is not valid tells them apart without a
        # warning: the block raises for it, while such a coder raises `JSON::GeneratorError`.
        def self.hands_text?(coder)
          coder.dump(["\xFF".b])
          false
        rescue IOStreams::Errors::InvalidEncoding
          true
        rescue StandardError
          false
        end
        private_class_method :hands_text?

        # Returns [String] the JSON of the record or value, as the JSON format writes a record, see #render, so that the
        # JSON text of a Hash or an Array value in another format, see `IOStreams::Schema::Field.any_text`, is the same.
        #
        # Raises `IOStreams::Errors::InvalidEncoding` for text that is not valid, see .json_text.
        #
        # The coder, see .coder, writes it in one pass in the json gem, whose block converts only the text that the gem
        # hands it. Without one, IOStreams converts the value in Ruby first, see .json_value, which takes several times
        # as long as the json gem takes to write it, then writes it with `to_json`.
        def self.generate(value, coder = self.coder)
          coder ? coder.dump(value) : json_value(value).to_json
        end

        # Returns the record or value as the JSON format writes it: each of its keys, String values and Symbol values as
        # UTF-8 text, see .json_text, and any other value that JSON does not hold as it is, such as a BigDecimal or a
        # Date, as `IOStreams::Schema::Field.any_json` converts it, see .generate. Returns the value itself, or a Hash or
        # an Array within it, when none of its values needs it, so that the record is copied only where it changes.
        #
        # Raises `IOStreams::Errors::InvalidEncoding` for text that is not valid, see .json_text.
        def self.json_value(value)
          case value
          when ::Hash then json_hash(value)
          when ::Array then json_array(value)
          when String then json_text(value)
          when Integer, Float, true, false, nil then value
          # JSON writes a Symbol as the text of its name.
          when Symbol then json_name(value)
          else
            json = IOStreams::Schema::Field.any_json(value)
            json.is_a?(String) ? json_text(json) : json
          end
        end

        # Returns [String] the text as JSON holds it, which is UTF-8: the text itself when it is already UTF-8, or ASCII,
        # the UTF-8 text of the bytes of binary text, such as a value read with `encoding("BINARY")`, as IOStreams 2.2
        # writes it with a schema, or text in another encoding converted to UTF-8.
        #
        # Raises `IOStreams::Errors::InvalidEncoding` for a character that is not valid, such as in binary text that is
        # not valid UTF-8, or that UTF-8 does not have, rather than the `JSON::GeneratorError` of the json gem, or the
        # `Encoding::UndefinedConversionError` of Ruby, since callers rescue the exceptions of IOStreams. The text is
        # checked a key or value at a time, before its line is written, so the error names its first invalid bytes and
        # their byte offset within that key or value, see `IOStreams::Encode.utf8_failure`.
        def self.json_text(text)
          return text if text.ascii_only? || (text.encoding == ::Encoding::UTF_8 && text.valid_encoding?)

          utf8_text(text) || raise(IOStreams::Encode.utf8_failure(text, place: "a key or value written to JSON").last)
        end

        # Returns [String|nil] the UTF-8 text of the bytes of binary text, or the text in another encoding converted to
        # UTF-8, or nil when it holds a character that is not valid, or that UTF-8 does not have, see .json_text.
        def self.utf8_text(text)
          case text.encoding
          when ::Encoding::UTF_8
            nil
          when ::Encoding::BINARY
            utf8 = text.dup.force_encoding(::Encoding::UTF_8)
            utf8 if utf8.valid_encoding?
          else
            text.encode(::Encoding::UTF_8)
          end
        rescue ::Encoding::InvalidByteSequenceError, ::Encoding::UndefinedConversionError
          nil
        end
        private_class_method :utf8_text

        # Returns [Hash] the hash as the JSON format writes it, see .json_value, or the hash itself when none of its keys
        # and values needs it. A key that is not text, such as an Integer, is kept, which JSON writes with `to_s`.
        #
        # A key or value that JSON writes as it is, such as ASCII text or a number, see .plain?, is taken as it is
        # without converting it, since most are.
        def self.json_hash(hash)
          copy  = nil
          index = 0
          hash.each_pair do |key, item|
            name = key.is_a?(String) && key.ascii_only? ? key : json_name(key)
            json = plain?(item) ? item : json_value(item)
            copy ||= hash.first(index).to_h unless name.equal?(key) && json.equal?(item)
            copy[name] = json if copy
            index += 1
          end
          copy || hash
        end
        private_class_method :json_hash

        # Returns [Array] the array as the JSON format writes it, see .json_value, or the array itself when none of its
        # values needs it.
        def self.json_array(array)
          copy = nil
          array.each_with_index do |item, index|
            next if plain?(item)

            json = json_value(item)
            (copy ||= array.dup)[index] = json unless json.equal?(item)
          end
          copy || array
        end
        private_class_method :json_array

        # Returns [true|false] whether JSON writes the value as it is: nil, true, false, an Integer, a Float, or ASCII
        # text, see .json_value. Ruby keeps what it found the first time that it checked the text, which the json gem
        # asks again as it writes it.
        def self.plain?(value)
          case value
          when String then value.ascii_only?
          when Integer, Float, true, false, nil then true
          else false
          end
        end
        private_class_method :plain?

        # Returns the key or Symbol value itself, or the UTF-8 text of one whose text, which JSON writes, is not UTF-8,
        # see .json_text. JSON writes a Symbol as its name, and a key that is neither text nor a Symbol with `to_s`, such
        # as an Integer, whose text is ASCII.
        def self.json_name(name)
          text =
            case name
            when String then name
            when Symbol then name.name
            when Integer, Float, true, false, nil then return name
            else name.to_s
            end
          json = json_text(text)
          json.equal?(text) ? name : json
        end
        private_class_method :json_name

        # The most keys whose fields it keeps, see #decimal_key?.
        DECIMAL_KEYS = 1000

        def initialize(schema: nil)
          super
          @coder = self.class.coder
          # Whether each key of the records is the column of a number field that keeps every digit, see #parse.
          @decimal_keys = {} if schema&.decimals?
        end

        # Returns [Hash] the record of the line, or nil for a line of `null`, which is a blank line. Returns the record or
        # row supplied, a Hash, or an Array that is already parsed, as it is, see `IOStreams::Tabular#record_parse`.
        #
        # With a schema that has a number field that keeps every digit, see `IOStreams::Schema#decimals?`, the numbers
        # of its column are read as BigDecimals, with every digit of their text, rather than through a Float, which keeps
        # about 16. Every other number is still a Float, the same as without a schema.
        #
        # Raises `IOStreams::Errors::TypeMismatch` for a line that is not an object, such as `[1,2]` or `5`, since only an
        # object has the keys that name its values.
        def parse(row)
          # Each line read is a String, so that is checked first.
          unless row.is_a?(String)
            return row if row.is_a?(::Hash) || row.is_a?(::Array)

            raise(IOStreams::Errors::TypeMismatch, "Format is :json. Invalid input: #{row.class.name}")
          end

          values = @decimal_keys ? parse_decimals(row) : JSON.parse(row)
          return values if values.is_a?(::Hash) || values.nil?

          raise(IOStreams::Errors::TypeMismatch, "Each line of the :json format must be an object, whose keys name its " \
                                                 "values, rather than #{values.class.name}")
        end

        # Returns [String] the record, by the names of its columns, as a single line JSON string.
        #
        # A BigDecimal, Date or Time is written as its text, see `IOStreams::Schema::Field.any_json`, such as "12.5"
        # rather than "0.125e2", so that a BigDecimal keeps all of its digits. Each key and String value is written as
        # UTF-8 text, which JSON holds, see .json_text, so binary text that is valid UTF-8, such as a value read with
        # `encoding("BINARY")`, is written as that text, with or without a schema.
        #
        # Raises `IOStreams::Errors::InvalidEncoding` for text that is not valid, such as binary text that is not valid
        # UTF-8, rather than the `JSON::GeneratorError` of the json gem.
        def render(row)
          self.class.generate(row, @coder)
        end

        def requires_header?
          false
        end

        private

        # Returns the value of the line, with the numbers of each key that is the column of a number field that keeps
        # every digit as BigDecimals, and every other number as a Float, see #parse.
        def parse_decimals(line)
          values = JSON.parse(line, decimal_class: ::BigDecimal)
          return values unless values.is_a?(::Hash)

          values.each_pair do |key, value|
            next unless value.is_a?(::BigDecimal) || value.is_a?(::Array) || value.is_a?(::Hash)

            values[key] = floats(value) unless decimal_key?(key)
          end
          values
        end

        # Returns [true|false] whether the key is the column of a number field that keeps every digit, worked out once
        # for each key, see `IOStreams::Schema#field_for`.
        def decimal_key?(key)
          @decimal_keys.fetch(key) do
            @decimal_keys.clear if @decimal_keys.size >= DECIMAL_KEYS
            @decimal_keys[key] = @schema.field_for(key, "key")&.decimal? || false
          end
        end

        # Returns the value, with each BigDecimal within it as a Float, as JSON reads a number without a schema.
        def floats(value)
          case value
          when ::BigDecimal then value.to_f
          when ::Array then value.map { |item| floats(item) }
          when ::Hash then value.transform_values { |item| floats(item) }
          else value
          end
        end
      end
    end
  end
end
