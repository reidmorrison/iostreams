require "json"
module IOStreams
  class Tabular
    module Parser
      class Array < Base
        # Returns Array
        def parse(row)
          raise(IOStreams::Errors::TypeMismatch, "Format is :array. Invalid input: #{row.class.name}") unless row.is_a?(::Array)

          row
        end

        def render(row, header)
          header.to_array(row)
        end
      end
    end
  end
end
