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
          IOStreams::Schema::Field.any_json(hash).to_json
        end

        def requires_header?
          false
        end
      end
    end
  end
end
