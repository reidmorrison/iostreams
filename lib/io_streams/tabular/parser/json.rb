require "json"
module IOStreams
  class Tabular
    module Parser
      # For parsing a single line of JSON at a time
      class Json < Base
        # Returns [true] each line is a JSON object, whose keys name its values.
        def self.keyed?
          true
        end

        # Returns [:json] JSON writes the numbers and booleans of a schema as themselves, and every other value as text.
        def self.value_form
          :json
        end

        # Returns [IOStreams::Tabular::Parser::JsonFields] the parser of the lines of JSON with the supplied schema,
        # which reads every digit of the numbers of its number fields, and writes them, see
        # `IOStreams::Tabular::Parser::Base.schema_parser`.
        def self.schema_parser(schema)
          JsonFields.new(schema)
        end

        def parse(row)
          return row if row.is_a?(::Hash)

          raise(IOStreams::Errors::TypeMismatch, "Format is :json. Invalid input: #{row.class.name}") unless row.is_a?(String)

          JSON.parse(row)
        end

        # Return the supplied array as a single line JSON string.
        def render(row, header)
          hash = header.to_hash(row)
          hash.to_json
        end

        def requires_header?
          false
        end
      end
    end
  end
end
