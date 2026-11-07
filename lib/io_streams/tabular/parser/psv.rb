# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      # For parsing a single line of Pipe-separated values
      class Psv < Base
        # The characters that a value is cleansed of when it is written, see #render.
        CLEANSED = /[|\r\n]/

        # Its `|` is found as ASCII, see `IOStreams::Tabular::Parser::Base.ascii_text?`.
        def self.ascii_text?
          true
        end

        # Parameters:
        #   schema: [IOStreams::Schema|nil]
        #     With a schema, the empty values at the end of a line, such as the last of `a|b|`, are empty text, `""`, as
        #     the empty values before them are, so that the missing values of their fields decide whether they are
        #     missing, see `IOStreams::Schema::Field#cast`, as CSV reads them. Without one, they are left out, so that
        #     their columns are nil, as they always were.
        def initialize(schema: nil)
          super
          @limit = schema.nil? ? 0 : -1
        end

        # Returns [Array] the parsed PSV line
        def parse(row)
          return row if row.is_a?(::Array)

          raise(IOStreams::Errors::TypeMismatch, "Format is :psv. Invalid input: #{row.class.name}") unless row.is_a?(String)

          row.split("|", @limit)
        end

        # Returns [String] the values of the row, in the order of its columns, as a single line PSV string.
        #
        # Since PSV has no escaping, any `|` within a value is replaced with `:`,
        # and any line break with a space, so that a value cannot add columns or records.
        # A value that is not a String is written as its text, see `IOStreams::Schema::Field.any_text`.
        def render(row)
          cleansed_array = row.collect do |value|
            next if value.nil?

            text = IOStreams::Schema::Field.any_text(value)
            CLEANSED.match?(text) ? text.tr("|", ":").gsub(LINE_BREAK, " ") : text
          end
          cleansed_array.join("|")
        end
      end
    end
  end
end
