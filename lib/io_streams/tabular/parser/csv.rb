module IOStreams
  class Tabular
    module Parser
      class Csv < Base
        attr_reader :csv_parser

        def initialize
          @csv_parser = Utility::CSVRow.new
        end

        # Returns [Array<String>] the header row.
        # Returns nil if the row is blank.
        def parse_header(row)
          raise(IOStreams::Errors::InvalidHeader, "Format is :csv. Invalid input header: #{row.class.name}") unless row.is_a?(String)

          csv_parser.parse(row)
        end

        # Returns [Array] the parsed CSV line
        def parse(row)
          raise(IOStreams::Errors::TypeMismatch, "Format is :csv. Invalid input: #{row.class.name}") unless row.is_a?(String)

          csv_parser.parse(row)
        end

        # Return the supplied array as a single line CSV string.
        def render(row, header)
          array = header.to_array(row)
          csv_parser.to_csv(array)
        end

      end
    end
  end
end
