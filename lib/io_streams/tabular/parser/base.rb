# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      class Base
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

        # Returns [true|false] whether each row of this format is a record, a Hash whose keys name its values, such as a
        # line of JSON, rather than its values in the order of its columns, an Array, such as a line of CSV. The parser
        # parses each line into a row of that form, and renders a row of that form, into which the mapping of the columns
        # arranges the row or record written, see `IOStreams::Tabular::Mapping`.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.keyed?
          false
        end

        # Returns [Module|nil] the format, see `IOStreams::StreamFormat`, whose reader and writer read and write the rows of a
        # format that holds them in a binary layout of its own, rather than as lines of text, such as `IOStreams::Parquet`,
        # see `IOStreams::Tabular#read_rows`, or nil for a format of lines, which a line reader splits.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.row_format
          nil
        end

        # Returns [true|false] whether a header row is required for this format.
        def requires_header?
          true
        end
      end
    end
  end
end
