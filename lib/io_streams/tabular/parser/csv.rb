require "csv"
module IOStreams
  class Tabular
    module Parser
      class Csv < Base
        # Frozen, so that using one does not create a string each time, as a string literal does in this file.
        QUOTE      = '"'.freeze
        COMMA      = ",".freeze
        CR         = "\r".freeze
        LF         = "\n".freeze
        EMPTY      = "".freeze
        QUOTE_BYTE = QUOTE.ord
        COMMA_BYTE = COMMA.ord

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

        # Returns [Array] the values of the line, the same as `CSV.parse_line`.
        #
        # `CSV.parse_line` creates a parser for each line, which costs several times more than parsing the line,
        # so the line is parsed here, except for a line that `CSV.parse_line` still parses:
        # * A line with a line break, which CSV takes as the end of the row unless it is quoted.
        # * A line with invalid quoting, so that CSV raises its own error for it.
        def parse_line(line)
          return if IOStreams::Utils.blank?(line)
          return CSV.parse_line(line) if line.include?(CR) || line.include?(LF)
          return split_line(line) unless line.include?(QUOTE)

          scan_line(line) || CSV.parse_line(line)
        end

        # Returns [Array] the values of a line without quotes, where an empty value is nil.
        def split_line(line)
          values = line.split(COMMA, -1)
          return values unless values.include?(EMPTY)

          values.map! { |value| value.empty? ? nil : value }
        end

        # Returns [Array] the values of a line with quotes, where an empty value is nil unless it is quoted.
        # Returns nil when the quoting is invalid.
        #
        # Reads one value at a time, starting at the byte at `position`. Uses `while` loops rather than blocks,
        # since JRuby leaves a block for `break` or `return` by raising an exception.
        def scan_line(line)
          values   = []
          size     = line.bytesize
          position = 0
          while position <= size
            if line.getbyte(position) == QUOTE_BYTE
              start = position + 1
              close = line.byteindex(QUOTE, start)
              value = close && line.byteslice(start, close - start)
              # The value ends at the first quote that is not doubled. A doubled quote is one quote in the value.
              while close && line.getbyte(close + 1) == QUOTE_BYTE
                start = close + 2
                close = line.byteindex(QUOTE, start)
                value << QUOTE << line.byteslice(start, close - start) if close
              end
              return unless close

              position = close + 1
              # Only a comma, or the end of the line, can follow the closing quote.
              return if position < size && line.getbyte(position) != COMMA_BYTE
            else
              comma = line.byteindex(COMMA, position) || size
              value = line.byteslice(position, comma - position)
              # A quote must enclose the whole value.
              return if value.include?(QUOTE)

              value    = nil if value.empty?
              position = comma
            end
            values << value
            # Skip the comma, or move past the end of the line after the last value.
            position += 1
          end
          values
        end

        def render_array(array)
          CSV.generate_line(array, encoding: "UTF-8", row_sep: "")
        end
      end
    end
  end
end
