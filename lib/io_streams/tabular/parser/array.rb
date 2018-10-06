require 'json'
module IOStreams
  class Tabular
    module Parser
      class Array < Base
        # Returns [Array<String>] the header row.
        # Returns nil if the row is blank.
        def parse_header(row)
          raise(IOStreams::Errors::InvalidHeader, "Format is :array. Invalid input header: #{row.class.name}") unless row.is_a?(::Array)
          row
        end

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
