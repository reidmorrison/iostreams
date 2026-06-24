require "csv"
module IOStreams
  class Tabular
    module Parser
      class Csv < Base
        # CSV fields may contain embedded delimiters and newlines when wrapped in double quotes.
        def self.quote_character
          '"'
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

        def parse_line(line)
          return if IOStreams::Utils.blank?(line)

          CSV.parse_line(line)
        end

        def render_array(array)
          CSV.generate_line(array, encoding: "UTF-8", row_sep: "")
        end
      end
    end
  end
end
