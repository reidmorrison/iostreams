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

        def initialize(schema: nil)
          super
          @coder = self.class.coder
        end

        def parse(row)
          return row if row.is_a?(::Hash)

          raise(IOStreams::Errors::TypeMismatch, "Format is :json. Invalid input: #{row.class.name}") unless row.is_a?(String)

          JSON.parse(row)
        end

        # Return the supplied array as a single line JSON string.
        #
        # A BigDecimal, Date or Time is written as its text, see `IOStreams::Schema::Field.any_json`, such as "12.5"
        # rather than "0.125e2", so that a BigDecimal keeps all of its digits.
        def render(row, header)
          hash = header.to_hash(row)
          @coder ? @coder.dump(hash) : IOStreams::Schema::Field.any_json(hash).to_json
        end

        def requires_header?
          false
        end
      end
    end
  end
end
