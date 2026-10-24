# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows that a slice reader reads, see `IOStreams::Slice::Reader`, when they are the lines of a file, which a line
    # reader reads, see `IOStreams::Line::Reader#each_with_line_number`, so that each row holds the line of the file that
    # it starts on, see `IOStreams::Slice#line_number_at`. The collector numbers each of them as the next record, see
    # `IOStreams::Slice#record_number_at`.
    class LineRows
      # Parameters
      #   lines: [IOStreams::Line::Reader]
      #     Yields each line of the file, with the line that it starts on, see
      #     `IOStreams::Line::Reader#each_with_line_number`.
      def initialize(lines)
        @lines = lines
      end

      # Adds each line to the supplied collector, see `IOStreams::Slice::Collector#add`, with the line of the file that
      # it starts on.
      #
      # Returns [Integer] the number of lines read, see `IOStreams::Line::Reader#each_with_line_number`.
      def add_to(collector)
        @lines.each_with_line_number { |line, line_number| collector.add(line, line_number) }
      end
    end
  end
end
