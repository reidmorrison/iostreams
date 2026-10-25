# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      # The `:lines` format: each line of the file is a row of one value, the whole line as it is, such as a file of
      # email addresses or ids, one on each line. It has no header row, no quoting and no separators, so a quote or a
      # comma is just a character of the line, and every line ending ends a row.
      #
      # A schema has one field, which names the value of each line and gives its type, so that `each(:hash)` keys each
      # record by it.
      class Lines < Base
        LINE_BREAK = /\r\n|\r|\n/

        # Parameters
        #   schema: [IOStreams::Schema|nil]
        #     The schema of the rows, which names the value of each line with its one field.
        #
        # Raises ArgumentError for a schema of more than one field, since each line is one value.
        def initialize(schema: nil)
          super
          return if schema.nil? || schema.fields.size == 1

          raise(ArgumentError, "Each line of the :lines format is one value, so its schema has one field, not " \
                               "#{schema.fields.size}")
        end

        # Returns [Array] the row of the line: the line as it is, its one value, or a row already parsed, an Array, as
        # it is.
        #
        # Raises `IOStreams::Errors::TypeMismatch` for anything else, such as a Hash.
        def parse(row)
          return row if row.is_a?(::Array)
          return [row] if row.is_a?(::String)

          raise(IOStreams::Errors::TypeMismatch, "Format is :lines. Invalid input: #{row.class.name}")
        end

        # Returns [String] the line of the row of one value, written as its text, see
        # `IOStreams::Schema::Field.any_text`. Since a line cannot hold a line break, it is replaced with a space, as
        # PSV and fixed width do, so that a value cannot add records.
        #
        # Raises `IOStreams::Errors::TypeMismatch` for a row of more than one value, which a line cannot hold.
        def render(row)
          if row.size > 1
            raise(IOStreams::Errors::TypeMismatch,
                  "Each row of the :lines format is one value, not #{row.size}: #{row.inspect}")
          end

          value = row.first
          return "" if value.nil?

          text = IOStreams::Schema::Field.any_text(value)
          LINE_BREAK.match?(text) ? text.gsub(LINE_BREAK, " ") : text
        end

        # Returns [false] a file of lines has no header row: a schema names the value of each line instead.
        def requires_header?
          false
        end
      end
    end
  end
end
