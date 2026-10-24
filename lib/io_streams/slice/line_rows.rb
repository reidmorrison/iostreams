# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows that a slice reader reads, see `IOStreams::Slice::Reader`, when they are the lines of a file, which a line
    # reader reads, see `IOStreams::Line::Reader#each_with_line_number`, so that each row holds the line of the file that
    # it starts on, see `IOStreams::Slice#line_number_at`.
    #
    # The line reader's own `#each` yields each line alone, as `IOStreams::Stream#each(:line)` and the reader that
    # `#reader(:line)` yields hand them on, so this yields its line number too.
    class LineRows
      # Parameters
      #   lines: [IOStreams::Line::Reader]
      #     Yields each line of the file, with the line that it starts on, see
      #     `IOStreams::Line::Reader#each_with_line_number`.
      def initialize(lines)
        @lines = lines
      end

      # Yields each line with the line of the file that it starts on.
      #
      # Returns [Integer] the number of lines read, see `IOStreams::Line::Reader#each_with_line_number`.
      def each(&)
        @lines.each_with_line_number(&)
      end
    end
  end
end
