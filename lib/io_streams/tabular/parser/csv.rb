# frozen_string_literal: true

require "csv"
module IOStreams
  class Tabular
    module Parser
      class Csv < Base
        # Frozen, so that using one does not create a string each time, as a string literal does in this file.
        QUOTE         = '"'
        ESCAPED_QUOTE = '""'
        COMMA         = ","
        CR            = "\r"
        LF            = "\n"
        EMPTY         = ""
        QUOTE_BYTE    = QUOTE.ord
        COMMA_BYTE    = COMMA.ord
        # The characters that a value is quoted for when it is written.
        QUOTABLE      = /[\r\n,"]/

        # Returns [CSV::MalformedCSVError] the supplied error of the csv gem, for a line whose quoting is not valid, tagged
        # as an `IOStreams::Errors::RowError`, so that the reader of the rows names the record and line of the file that
        # it is in, rather than the line within the text of the row that the gem names, since it reads one row at a
        # time, such as "Illegal quoting, in record 3 on line 5" for the gem's "Illegal quoting in line 1.". Its class,
        # and `#lineno`, the gem's line within the row, are kept.
        def self.row_error(error)
          IOStreams::Errors::RowError.tag(error, error.message.delete_suffix(" in line #{error.lineno}."))
        end

        # CSV fields may contain embedded delimiters and newlines when wrapped in double quotes.
        def self.quote_character
          '"'
        end

        # Its commas and quotes are found as ASCII, see `IOStreams::Tabular::Parser::Base.ascii_text?`.
        def self.ascii_text?
          true
        end

        # Returns [String] the supplied text of a row, that a format that holds the text of each row as it is writes as
        # CSV, such as `:text` written to a spreadsheet, as one row of CSV, see
        # `IOStreams::Tabular::Parser::Base.one_row`, as it is, once it checks that its quoting is valid.
        #
        # Raises `IOStreams::Errors::TypeMismatch` for text that is not one row of CSV, such as `"jill"@example.com`,
        # whose quotes do not enclose the whole value, rather than write it, so that writing it raises an error of
        # IOStreams, rather than that of the csv gem that the CSV of a spreadsheet would raise.
        def self.one_row(text)
          line = super
          return line unless line.include?(QUOTE)

          CSV.parse_line(line)
          line
        rescue CSV::MalformedCSVError
          raise(IOStreams::Errors::TypeMismatch, "The text of the row is not a row of CSV, in which a quote encloses a " \
                                                 "whole value and a quote within it is doubled: #{text.inspect}")
        end

        # Parameters:
        #   schema: [IOStreams::Schema|nil]
        #     With a schema, an empty value without quotes, such as the middle value of `a,,b`, is empty text, `""`, as
        #     a value within quotes, `""`, is, so that the missing values of its field decide whether it is missing, see
        #     `IOStreams::Schema::Field#cast`, as for the other formats, rather than always `nil`. Without one, it is `nil`,
        #     as it always was, while `""` is empty text.
        def initialize(schema: nil)
          super
          @empty_text = !schema.nil?
        end

        # Returns [Array] the parsed CSV line
        #
        # Raises `CSV::MalformedCSVError` for a line whose quoting is not valid, tagged as an
        # `IOStreams::Errors::RowError`, see .row_error.
        def parse(row)
          return row if row.is_a?(::Array)

          raise(IOStreams::Errors::TypeMismatch, "Format is :csv. Invalid input: #{row.class.name}") unless row.is_a?(String)

          parse_line(row)
        end

        # Returns [String] the values of the row, in the order of its columns, as a single line CSV string.
        def render(row)
          render_array(row)
        end

        private

        # Returns [Array] the values of the line, the same as `CSV.parse_line`, apart from an empty value without quotes,
        # which is empty text with a schema, see #initialize, as `CSV.parse_line` reads it with `nil_value: ""`.
        #
        # `CSV.parse_line` creates a parser for each line, which costs several times more than parsing the line,
        # so the line is parsed here, except for a line that `CSV.parse_line` still parses:
        # * A line with a line break, which CSV takes as the end of the row unless it is quoted.
        # * A line with invalid quoting, so that CSV raises its own error for it.
        def parse_line(line)
          return if IOStreams::Utils.blank?(line)
          return csv_parse_line(line) if line.include?(CR) || line.include?(LF)
          return split_line(line) unless line.include?(QUOTE)

          scan_line(line) || csv_parse_line(line)
        end

        # Returns [Array] the values of the line that `CSV.parse_line` reads, an empty value without quotes as empty text
        # with a schema, see #initialize, in the encoding of the line, as #split_line reads it, and a String of its own,
        # rather than the one `nil_value:` of the csv gem, which every empty value of every line would share.
        #
        # Raises `CSV::MalformedCSVError` for a line whose quoting is not valid, tagged as an
        # `IOStreams::Errors::RowError`, see .row_error.
        def csv_parse_line(line)
          values = CSV.parse_line(line)
          return values unless @empty_text && values

          values.map! { |value| value.nil? ? line[0, 0] : value }
        rescue CSV::MalformedCSVError => e
          raise(self.class.row_error(e))
        end

        # Returns [Array] the values of a line without quotes, where an empty value is nil, or empty text with a schema,
        # see #initialize.
        def split_line(line)
          values = line.split(COMMA, -1)
          return values if @empty_text || !values.include?(EMPTY)

          values.map! { |value| value.empty? ? nil : value }
        end

        # Returns [Array] the values of a line with quotes, where an empty value is nil unless it is quoted, or empty text
        # with a schema, see #initialize.
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

              value    = nil if !@empty_text && value.empty?
              position = comma
            end
            values << value
            # Skip the comma, or move past the end of the line after the last value.
            position += 1
          end
          values
        end

        # Returns [String] the values as a line, the same as `CSV.generate_line`.
        #
        # Like `CSV.parse_line`, `CSV.generate_line` creates a CSV object for each line, so the line is written here,
        # unless a value is text that is neither valid UTF-8 nor ASCII, which `CSV.generate_line` still writes, so
        # that the line and any error are the same.
        def render_array(array)
          render_line(array) ||
            CSV.generate_line(array.map { |value| value && IOStreams::Schema::Field.any_text(value) },
                              encoding: "UTF-8", row_sep: "")
        end

        # Returns [String] the values as a UTF-8 line, or nil when a value is text that is neither valid UTF-8 nor ASCII.
        #
        # Like CSV, a nil value is written as nothing, and any other value is quoted when it is empty, or contains a quote,
        # a comma or a line break. A value that is not a String is written as its text, see
        # `IOStreams::Schema::Field.any_text`, such as a BigDecimal as "12.5" rather than "0.125e2".
        def render_line(values)
          line  = +""
          index = 0
          while index < values.size
            value = values[index]
            line << COMMA if index.positive?
            index += 1
            next if value.nil?

            value = IOStreams::Schema::Field.any_text(value) unless value.is_a?(String)
            return unless (value.encoding == Encoding::UTF_8 || value.ascii_only?) && value.valid_encoding?

            if value.empty? || QUOTABLE.match?(value)
              line << QUOTE << value.gsub(QUOTE, ESCAPED_QUOTE) << QUOTE
            else
              line << value
            end
          end
          line
        end
      end
    end
  end
end
