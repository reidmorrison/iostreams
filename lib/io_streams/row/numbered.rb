# frozen_string_literal: true

module IOStreams
  module Row
    # Numbers the rows that a reader of rows or records reads, see `IOStreams::Row::Reader` and
    # `IOStreams::Record::Reader`, so that a value that is not valid for its field names the record that it is in, and
    # the line that the record starts on, see `IOStreams::Errors::InvalidValue#at`, and so that `on_invalid:` hands the
    # whole of a bad row to its handler, see `IOStreams::InvalidRow`, rather than raise.
    #
    # The lines that it reads say where each one starts when they can: a line reader, see
    # `IOStreams::Line::Reader#each_with_line_number`, or the rows of a slice, which also give their record numbers,
    # see `IOStreams::Slice::Stream`. The rows of a source without lines, such as Parquet or a query, start on no line.
    module Numbered
      # Raises ArgumentError for an `on_invalid:` that is neither nil nor callable, such as a Proc or a Method.
      def self.check_on_invalid(on_invalid)
        return if on_invalid.nil? || on_invalid.respond_to?(:call)

        raise(ArgumentError, "on_invalid: must be callable, such as ->(row) { problems << row }: #{on_invalid.inspect}")
      end

      private

      # Yields each line or row that the reader reads, with the line of the file that it starts on, or nil, and the
      # record number that its source gives, or nil, so that the reader counts them. A line reader yields each line, a
      # String, with its line number, to the block as it is. The rows of any other source are yielded one at a time, so
      # that a row that is an Array, such as of a query, is not spread over the arguments of the block.
      #
      # Returns the result of the `#each` of the lines.
      def each_numbered(&)
        if @line_reader.respond_to?(:each_with_numbers)
          @line_reader.each_with_numbers(&)
        elsif @line_reader.respond_to?(:each_with_line_number)
          @line_reader.each_with_line_number(&)
        else
          @line_reader.each { |row| yield(row, nil, nil) }
        end
      end

      # Returns [nil] once the supplied error, of a value of the supplied line, is handed to the handler of
      # `on_invalid:` as its row, see `IOStreams::InvalidRow`, which holds an error for each of its fields whose value is
      # not valid, so that the reader carries on with the next row. Without a handler, raises the error, which names the
      # record and line, see `IOStreams::Errors::InvalidValue#at`.
      #
      # The reader parses the line within its own rescue, never calling the block of its caller there, so that an
      # `InvalidValue` that the block raises is not taken for one of the row.
      def invalid(error, line, line_number, record_number)
        error.at(line_number: line_number, record_number: record_number)
        raise error unless @on_invalid

        errors = @tabular.value_errors(line)
        errors = [error] if errors.empty?
        errors.each { |each_error| each_error.at(line_number: line_number, record_number: record_number) }
        @on_invalid.call(IOStreams::InvalidRow.new(row: line, line_number: line_number, record_number: record_number,
                                                   errors: errors))
        nil
      end
    end
  end
end
