require 'json'
module IOStreams
  class Tabular
    module Parser
      class Hash < Base
        def parse(row)
          unless row.is_a?(::Hash)
            raise(IOStreams::Errors::TypeMismatch, "Format is :hash. Invalid input: #{row.class.name}")
          end

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
