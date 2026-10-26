# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      # The `:text` format: each row is one value, the text of the row as it is, without parsing it, such as a file of
      # email addresses or ids, one on each line. It has no header row, no quoting and no separators, so a quote or a
      # comma is just a character of its text.
      #
      # The rows of a plain file are its lines, which end where the line reader ends them, see
      # `IOStreams::Line::Reader`: at a "\n", without the "\r" before it, or in a file whose first line ends with a "\r"
      # alone, at a "\r", so a "\r" alone within a line of any other file is a character of its value. The rows of text
      # whose format a stream decides, such as the CSV of a spreadsheet, are split as that format splits them, so that a
      # quoted value with a line break stays in its row, see `IOStreams::Tabular#quote_character`, and each row is its
      # text in that format, see `.verbatim?`.
      #
      # A schema has one field, which names the value of each row and gives its type, so that `each(:hash)` keys each
      # record by it.
      class Text < Base
        LINE_BREAK = /\r\n|\r|\n/

        # Returns [true] each row is the text of a row of any format of lines, as it is, see
        # `IOStreams::Tabular::Parser::Base.verbatim?`.
        def self.verbatim?
          true
        end

        # Parameters
        #   schema: [IOStreams::Schema|nil]
        #     The schema of the rows, which names the value of each row with its one field.
        #
        # Raises ArgumentError for a schema of more than one field, since each row is one value.
        def initialize(schema: nil)
          super
          return if schema.nil? || schema.fields.size == 1

          raise(ArgumentError, "Each row of the :text format is one value, so its schema has one field, not " \
                               "#{schema.fields.size}")
        end

        # Returns [Array] the row of the text: the text as it is, its one value, or a row already parsed, an Array, as
        # it is.
        #
        # Raises `IOStreams::Errors::TypeMismatch` for anything else, such as a Hash.
        def parse(row)
          return row if row.is_a?(::Array)
          return [row] if row.is_a?(::String)

          raise(IOStreams::Errors::TypeMismatch, "Format is :text. Invalid input: #{row.class.name}")
        end

        # Returns [String] the text of the row of one value, see `IOStreams::Schema::Field.any_text`. Since a line
        # cannot hold a line break, it is replaced with a space, as PSV and fixed width do, so that a value cannot add
        # rows.
        #
        # Raises `IOStreams::Errors::TypeMismatch` for a row of more than one value, which the text of a row cannot hold.
        def render(row)
          if row.size > 1
            raise(IOStreams::Errors::TypeMismatch,
                  "Each row of the :text format is one value, not #{row.size}: #{row.inspect}")
          end

          value = row.first
          return "" if value.nil?

          text = IOStreams::Schema::Field.any_text(value)
          LINE_BREAK.match?(text) ? text.gsub(LINE_BREAK, " ") : text
        end

        # Returns [false] text has no header row: a schema names the value of each row instead.
        def requires_header?
          false
        end
      end
    end
  end
end
