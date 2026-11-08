# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      class Base
        # A line break, which ends a line of text, see .one_row.
        LINE_BREAK = /\r\n|\r|\n/

        # Parameters:
        #   schema: [IOStreams::Schema|nil]
        #     The schema of the rows, which a format needs when the schema says where each value is, such as the
        #     width of each field of a fixed width file, see `IOStreams::Tabular::Parser::Fixed`.
        def initialize(schema: nil)
          @schema = schema
        end

        # Returns [:text|:json|:typed] the form in which this format writes the values of a schema, see
        # `IOStreams::Schema::Field#render`: as text, the default.
        def self.value_form
          :text
        end

        # Returns [String] the type of field of the values that this format reads without a schema, which the schema
        # that a file declares gives each of its columns, see `IOStreams::Stream#infer_schema`: "string" for a format
        # of text, such as CSV, otherwise "any", such as for JSON, each of whose values has a type of its own.
        def self.value_type
          value_form == :text ? "string" : "any"
        end

        # Returns [true|false] whether each record supplies its own keys, and leaves out the key of a value that is missing,
        # such as JSON, so that a schema reads a key that a record leaves out as a missing value, nil, rather than a
        # missing column, see `IOStreams::Schema::Columns#initialize`: false for a format of columns, such as CSV.
        def self.keys_vary?
          false
        end

        # Returns [true|false] whether a row of the format whose every value is blank is a blank row, read as nil, as a
        # line of CSV of only commas is, and written as a blank line, see `IOStreams::Tabular#blank_rows?`: false for a
        # format whose every row is a record that was written as one, such as Parquet, which holds no blank lines, so
        # that a record written without values, such as `{}`, is written as a row of nulls.
        def self.blank_rows?
          true
        end

        # Returns [#read|nil] the times of day of the rows of the format, when it holds them as clocks without a zone, such
        # as Parquet, in the columns that the schema of the file, which the block returns, declares as `time`, read by
        # the fields of the supplied schema that reads the rows, see `IOStreams::Tabular#read_declared`, or nil for any
        # other format, whose values hold their own offset, or are text, which the fields read themselves, without
        # calling the block.
        def self.clocks(_schema)
          nil
        end

        # Returns [true|false] whether the format takes the position of each value of a line from a schema, such as fixed
        # width, which a contract never gives, see `IOStreams::Contract`, rather than from the line itself.
        def self.layout?
          false
        end

        # Returns [String] the quote character within which field delimiters and embedded
        # newlines may appear for this format, or [nil] when the format has no such quoting.
        #
        # Used by the line reader to avoid treating a newline as a line ending when it is
        # embedded within a quoted field (e.g. CSV). Defined at the class level since it is a
        # static property of the format, independent of any per-instance format options.
        def self.quote_character
          nil
        end

        # Returns [String] the encoding that text in this format is read and written in, when the caller does not set
        # one on the encode stream, or [nil] for the default encoding of the encode stream, UTF-8.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.encoding
          nil
        end

        # Returns [true|false] whether this format parses only lines of text in an encoding that is ASCII compatible,
        # since it finds the characters that separate and quote its values as ASCII, such as CSV, so that it cannot
        # parse text in an encoding such as UTF-16LE, see `IOStreams::Tabular#check_text_encoding`. False for a format
        # that parses text in any encoding, such as JSON, whose parser reads UTF-16 as UTF-8, or fixed width, which
        # counts characters.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.ascii_text?
          false
        end

        # Returns [true|false] whether the values of the rows that this format parses are UTF-8, whatever the encoding of
        # their text, such as JSON, whose parser reads UTF-16 as UTF-8, so that a schema reads them, see
        # `IOStreams::Tabular#check_text_encoding`. False for a format whose values are in the encoding of its text.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.utf8_values?
          false
        end

        # Returns [true|false] whether each row of this format is a record, a Hash whose keys name its values, such as a
        # line of JSON, rather than its values in the order of its columns, an Array, such as a line of CSV. The parser
        # parses each line into a row of that form, and renders a row of that form, into which the mapping of the columns
        # arranges the row or record written, see `IOStreams::Tabular::Mapping`.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.keyed?
          false
        end

        # Returns [true|false] whether each row of this format is the text of a row of any format of lines, as it is,
        # without parsing it, such as `:text`, so that it also reads the rows of text whose format a stream decides,
        # such as the CSV of a spreadsheet, see `IOStreams::Tabular::Settings#rows_format`, split as that format splits
        # them, see `IOStreams::Tabular#quote_character`. False for a format that parses its rows.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.verbatim?
          false
        end

        # Returns [String] the supplied text of a row, that a format that holds the text of each row as it is writes in
        # this format, see .verbatim?, such as `:text` written to a spreadsheet, whose rows are CSV, as one row of this
        # format: a line break that would end the row, outside a quoted value, see .quote_character, is replaced with a
        # space, so that the text cannot add rows, as PSV and fixed width do for their values. A line break within a
        # quoted value is kept, since it is part of the value.
        #
        # Defined at the class level since it depends only on how the format quotes its values, see .quote_character.
        #
        # Raises `IOStreams::Errors::TypeMismatch` when a quoted value is not closed, which would join the rows after it.
        def self.one_row(text)
          quote = quote_character
          if quote.nil? || !text.include?(quote)
            return LINE_BREAK.match?(text) ? text.gsub(LINE_BREAK, " ") : text
          end

          if text.count(quote).odd?
            raise(IOStreams::Errors::TypeMismatch, "The text of the row opens a quoted value that it does not close, " \
                                                   "which would join the rows after it: #{text.inspect}")
          end
          return text unless LINE_BREAK.match?(text)

          quoted = false
          text.gsub(/#{Regexp.escape(quote)}|#{LINE_BREAK.source}/) do |match|
            if match == quote
              quoted = !quoted
              match
            else
              quoted ? match : " "
            end
          end
        end

        # Returns [Module|nil] the format, see `IOStreams::StreamFormat`, whose reader and writer read and write the rows of a
        # format that holds them in a binary layout of its own, rather than as lines of text, such as `IOStreams::Parquet`,
        # see `IOStreams::Tabular#read_rows`, or nil for a format of lines, which a line reader splits.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.row_format
          nil
        end

        # Returns [true|false] whether this format reads the supplied row, see #parse, so that a slice of its rows
        # raises as soon as it is given one that it does not, see `IOStreams::Slice#add`, rather than when its rows are
        # read, where the slice was processed: a line of text, a String, a row already parsed, an Array, as every parser
        # takes one, or nil, a blank row. A format of keyed records, or of Ruby objects, reads other rows, see its own
        # `.row?`. It decides by the class of the row alone, never by its contents, so that rows of the class of one
        # that it reads are read too, see .unread_row_index, which a format that decides otherwise overrides, such as
        # `:text`, see `IOStreams::Tabular::Parser::Text.row?`.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.row?(row)
          row.is_a?(::String) || row.is_a?(::Array) || row.nil?
        end

        # Returns [Integer|nil] the index of the first of the supplied rows that this format does not read, see .row?,
        # or nil when it reads them all, such as the rows that a slice is built with, see `IOStreams::Slice.new`. The
        # rows of a slice are nearly always of one class, such as the lines of CSV, which `Array#all?` checks without
        # calling a block for each row, so that a slice read back from where it was stored, see `IOStreams.slice`, is
        # checked at little cost. Rows of several classes, such as blank rows among them, are checked one at a time.
        def self.unread_row_index(rows)
          first = rows.first
          return if !first.nil? && row?(first) && rows.all?(first.class)

          rows.index { |row| !row?(row) }
        end

        # Returns [String] the rows that this format reads, see .row?, as a slice that is given another says them, see
        # `IOStreams::Slice#add`.
        def self.rows_read
          "a line of text, or an Array of its values"
        end

        # Returns [true|false] whether a header row is required for this format.
        def requires_header?
          true
        end

        # Returns [String] the supplied line of a row of this format, read as it is, as the line that is written for it,
        # see `IOStreams::Tabular#written_line`: as it is, since it holds one row of this format. A format that holds the
        # text of each row as it is, see .verbatim?, writes it as one row of its lines instead, see .one_row.
        def written_line(line)
          line
        end
      end
    end
  end
end
