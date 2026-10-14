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

        # Returns [JSON::Coder|nil] a coder that writes a record as `IOStreams::Schema::Field.any_json(record).to_json`
        # does, in one pass over its values in the json gem, rather than one pass in Ruby, then another to write them.
        #
        # Returns nil before json 2.10, which added `JSON::Coder`, for a version whose coder does not write a key that is
        # not a String the same way, and when another library, such as ActiveSupport, has replaced `Hash#to_json`, since
        # the coder would not write the JSON that it does.
        def self.coder
          return unless ::Hash.instance_method(:to_json).owner.name&.start_with?("JSON::")
          return @coder if defined?(@coder)

          @coder = build_coder
        end

        def self.build_coder
          return unless defined?(::JSON::Coder) && defined?(::JSON::Fragment)

          coder = ::JSON::Coder.new do |value, key|
            # Like `Hash#to_json`, which writes a key that is not a String with `to_s`.
            next value.to_s if key

            json = IOStreams::Schema::Field.any_json(value)
            json.equal?(value) ? ::JSON::Fragment.new(value.to_json) : json
          end
          coder if coder.dump({1 => nil}) == '{"1":null}'
        rescue StandardError
          nil
        end
        private_class_method :build_coder

        # The most keys whose fields it keeps, see #decimal_key?.
        DECIMAL_KEYS = 1000

        def initialize(schema: nil)
          super
          @coder = self.class.coder
          # Whether each key of the records is the column of a number field that keeps every digit, see #parse.
          @decimal_keys = {} if schema&.decimals?
        end

        # Returns [Hash] the record of the line.
        #
        # With a schema that has a number field that keeps every digit, see `IOStreams::Schema#decimals?`, the numbers
        # of its column are read as BigDecimals, with every digit of their text, rather than through a Float, which keeps
        # about 16. Every other number is still a Float, the same as without a schema.
        def parse(row)
          return row if row.is_a?(::Hash)

          raise(IOStreams::Errors::TypeMismatch, "Format is :json. Invalid input: #{row.class.name}") unless row.is_a?(String)
          return JSON.parse(row) unless @decimal_keys

          values = JSON.parse(row, decimal_class: ::BigDecimal)
          return floats(values) unless values.is_a?(::Hash)

          values.each_pair do |key, value|
            next unless value.is_a?(::BigDecimal) || value.is_a?(::Array) || value.is_a?(::Hash)

            values[key] = floats(value) unless decimal_key?(key)
          end
          values
        end

        # Returns [String] the record, by the names of its columns, as a single line JSON string.
        #
        # A BigDecimal, Date or Time is written as its text, see `IOStreams::Schema::Field.any_json`, such as "12.5"
        # rather than "0.125e2", so that a BigDecimal keeps all of its digits.
        def render(row)
          @coder ? @coder.dump(row) : IOStreams::Schema::Field.any_json(row).to_json
        end

        def requires_header?
          false
        end

        private

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
