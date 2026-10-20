require "json"
module IOStreams
  class Tabular
    module Parser
      class Hash < Base
        # Returns [true] each row is a Hash, whose keys name its values.
        def self.keyed?
          true
        end

        # Returns [:typed] each row is a Ruby object, so it holds the values of a schema themselves.
        def self.value_form
          :typed
        end

        def parse(row)
          raise(IOStreams::Errors::TypeMismatch, "Format is :hash. Invalid input: #{row.class.name}") unless row.is_a?(::Hash)

          row
        end

        def render(row, header)
          header.to_hash(row)
        end

        def requires_header?
          false
        end
      end
    end
  end
end
