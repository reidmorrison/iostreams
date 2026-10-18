# frozen_string_literal: true

module IOStreams
  class Slice
    # Parses the rows of slices, see `IOStreams::Slice`, by a schema set once, as on a path, for a worker that processes
    # many slices, see `IOStreams.sliced`:
    #
    #   sliced = IOStreams.sliced.schema(IOStreams.schema("people.json"))
    #   queue.each do |slice|
    #     rows = sliced.slice(slice)
    #     rows.each(:hash) { |person| process(person, rows.line_number) }
    #   end
    #
    # The schema is read once, and the columns of each header row are matched to its fields once, for every slice that
    # shares the header row and format, rather than for each slice, as a path set up for each slice would.
    #
    # A pipeline keeps what it has matched for the slices, so give each thread its own. Fibers on one thread can share
    # one, since a row is parsed before it is yielded.
    class Pipeline
      # The default of the options of #slice, which take what the slice carries, distinct from nil, which is not known.
      FROM_SLICE = Object.new.freeze
      private_constant :FROM_SLICE

      def initialize
        @format   = nil
        @schema   = nil
        @source   = nil
        @tabulars = {}
      end

      # Set/get the tabular format of the rows of the slices that do not carry their own, such as `:csv`, see
      # `IOStreams::Slice#format`. A slice read with `IOStreams::Stream#each(:slice)` carries its format, which applies to
      # it instead. Without either, the rows are read as CSV.
      #
      # Raises ArgumentError for a format that is not registered, see `IOStreams.tabular_formats`.
      def format(format = :none)
        return @format if format == :none

        format = format.to_sym if format.is_a?(String)
        unless format.nil? || IOStreams.tabular_formats.include?(format)
          raise(ArgumentError, "Invalid format: #{format.inspect}")
        end

        @format = format
        @tabulars.clear
        self
      end

      # Set/get the schema of the rows, as `IOStreams::Stream#schema` sets the schema of a path: a Hash, the path or url
      # of a JSON file, which is read the first time that a slice is parsed, and then kept, or a schema already read with
      # `IOStreams.schema`. nil removes it.
      #
      # Raises ArgumentError when the schema is none of them, or is a Hash that is not a valid schema.
      def schema(schema = :none)
        return @schema if schema == :none

        schema  = schema.is_a?(IOStreams::Stream) ? schema.dup.freeze : Utils.frozen_copy(schema)
        @source = schema.nil? ? nil : IOStreams::Schema::Source.new(schema)
        @schema = schema
        @tabulars.clear
        self
      end

      # Returns [IOStreams::Slice::Rows] the rows of the supplied slice, which its #each reads in this pipeline's schema.
      #
      # Parameters
      #   rows: [IOStreams::Slice|String|#each]
      #     A slice, the bytes of a slice, see `IOStreams::Slice#serialize`, which are read back first, see
      #     `IOStreams.slice`, or the rows of one, such as an Array of lines read back from where they were stored.
      #
      #   header: [Array<String>]
      #     The header row of the file that the rows came from, as it was read, see `IOStreams::Slice#header`.
      #     Default: the header row of the slice, or nil for rows without one.
      #
      #   line_number: [Integer]
      #     The line of the file that the first row is on, see `IOStreams::Slice#line_number`.
      #     Default: the line number of the slice, or nil, which is not known.
      #
      #   format: [Symbol]
      #     The tabular format of the rows, see `IOStreams::Slice#format`.
      #     Default: the format of the slice, otherwise the format of this pipeline, see #format.
      def slice(rows, header: FROM_SLICE, line_number: FROM_SLICE, format: FROM_SLICE)
        rows        = IOStreams.slice(rows) if rows.is_a?(String)
        header      = from_slice(rows, :header) if header.equal?(FROM_SLICE)
        line_number = from_slice(rows, :line_number) if line_number.equal?(FROM_SLICE)
        format      = from_slice(rows, :format) if format.equal?(FROM_SLICE)
        Rows.new(rows, tabular: tabular(format || @format || :csv, header), line_number: line_number)
      end

      # Returns [String] the class, the format and the schema, rather than every instance variable, such as the tabulars
      # that it keeps.
      def inspect
        "#<#{self.class.name} format=#{@format.inspect} schema=#{@schema.inspect}>"
      end

      private

      # What the slice carries, when the rows are a slice, otherwise nil, see #slice.
      def from_slice(rows, name)
        rows.public_send(name) if rows.is_a?(Slice)
      end

      # Returns [IOStreams::Tabular] that parses the rows of the format, once it has read the header row, which is kept
      # for every slice of the same format and header row.
      def tabular(format, header)
        unless header.nil? || header.is_a?(Array)
          raise(ArgumentError, "Invalid header #{header.inspect}: supply the header row of the file as an Array, or nil")
        end

        @tabulars[[format, header]] ||= begin
          tabular = IOStreams::Tabular.new(format: format, schema: @source&.schema)
          tabular.read_header(header) if header && tabular.header?
          tabular
        end
      end
    end
  end
end
