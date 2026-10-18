# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows of one slice, which `IOStreams::Slice::Pipeline#slice` returns, read as lines, rows or records by the
    # format and schema of the pipeline, and the header row of the slice.
    class Rows
      # The modes that #each reads the rows in, as `IOStreams::Stream#each` reads the rows of a file.
      MODES = %i[line array hash].freeze

      # Returns [Integer] while #each runs, the line of the file that the row that it is reading is on, see
      # `IOStreams::Slice#line_number`, so that the block can name it when it fails to process the row. After #each, the
      # line after the last row. nil when the line of the first row is not known.
      attr_reader :line_number

      # Parameters
      #   rows: [#each]
      #     The rows of the slice.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each row, once it has read the header row of the slice.
      #
      #   line_number: [Integer|nil]
      #     The line of the file that the first row is on.
      def initialize(rows, tabular:, line_number: nil)
        raise(ArgumentError, "rows must respond to #each") unless rows.respond_to?(:each)
        unless line_number.nil? || (line_number.is_a?(Integer) && line_number.positive?)
          raise(ArgumentError, "Invalid line_number #{line_number.inspect}: supply the line of the first row, or nil")
        end

        @rows        = rows
        @tabular     = tabular
        @first_line  = line_number
        @line_number = line_number
      end

      # Yields each row of the slice, in the supplied mode:
      #   :hash
      #     Each record, a Hash by the names of the fields of the schema, or by the columns of the header row without one,
      #     or nil for a blank line, see `IOStreams::Tabular#record_parse`.
      #   :array
      #     Each row, the values of the fields in order, or nil for a blank line, see `IOStreams::Tabular#row_parse`.
      #     Unlike `IOStreams::Stream#each(:array)`, the header row is not yielded first, since the slice carries it.
      #   :line
      #     Each row as it is in the file.
      #
      # A value that is not valid raises with the line of the file that it is on, see
      # `IOStreams::Errors::Error#line_number`, and #line_number gives the line of the row while the block runs.
      #
      # Returns [Integer] the number of rows.
      def each(mode = :hash)
        unless MODES.include?(mode)
          raise(ArgumentError, "Invalid mode: #{mode.inspect}. Valid modes: #{MODES.map(&:inspect).join(', ')}")
        end

        @line_number = @first_line
        count        = 0
        @rows.each do |row|
          yield parse(mode, row)
          count += 1
          next_line(row)
        end
        count
      end

      # Returns [String] the class and the format of the rows, rather than every instance variable, such as the rows.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end

      private

      # Returns the row in the mode, see #each, naming the line of the file that a value that is not valid is on.
      def parse(mode, row)
        case mode
        when :hash then @tabular.record_parse(row)
        when :array then @tabular.row_parse(row)
        else row
        end
      rescue IOStreams::Errors::Error => e
        e.line_number = @line_number if @line_number
        raise
      end

      # Moves #line_number past the row: one line, and one more for each line break within a quoted value.
      def next_line(row)
        return unless @line_number

        @line_number += row.is_a?(String) ? row.count("\n") + 1 : 1
      end
    end
  end
end
