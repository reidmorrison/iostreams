require 'csv'
module IOStreams
  class Tabular
    module Parser
      class Csv < Base
        attr_reader :csv_parser

        def initialize
          @csv_parser = Utility::CSVRow.new unless RUBY_VERSION.to_f >= 2.6
        end

        # Returns [Array<String>] the header row.
        # Returns nil if the row is blank.
        def parse_header(row)
          return row if row.is_a?(::Array)

          raise(IOStreams::Errors::InvalidHeader, "Format is :csv. Invalid input header: #{row.class.name}") unless row.is_a?(String)

          parse_line(row)
        end

        # Returns [Array] the parsed CSV line
        def parse(row)
          return row if row.is_a?(::Array)

          raise(IOStreams::Errors::TypeMismatch, "Format is :csv. Invalid input: #{row.class.name}") unless row.is_a?(String)

          parse_line(row)
        end

        # Return the supplied array as a single line CSV string.
        def render(row, header)
          array = header.to_array(row)
          render_array(array)
        end

        private

        if RUBY_VERSION.to_f >= 2.6
          # About 10 times slower than the approach used in Ruby 2.5 and earlier,
          # but at least it works on Ruby 2.6 and above.
          def parse_line(line)
            return if IOStreams.blank?(line)

            CSV.parse_line(line)
          end

          def render_array(array)
            CSV.generate_line(array, encoding: 'UTF-8', row_sep: '')
          end
        else
          def parse_line(line)
            csv_parser.parse(line)
          end

          def render_array(array)
            csv_parser.to_csv(array)
          end
        end
      end
    end
  end
end
