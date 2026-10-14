# frozen_string_literal: true

module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row, for `IOStreams::Stream#each(:hash)` and
    # `#reader(:hash)`, which create it with the tabular of the stream, whose options are documented with
    # `IOStreams::Tabular.new`.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads records, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Line::Reader.option_names`, and those of the
      # `IOStreams::Tabular` that parses them, see `IOStreams::Tabular.read_option_names`.
      def self.option_names
        [*IOStreams::Line::Reader.option_names, *IOStreams::Tabular.read_option_names]
      end

      # Create a reader to return the stream as Hash records.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, holds the header, and cleanses the header row as its `cleanse_header`
      #     option says, see `IOStreams::Tabular.new`.
      def initialize(line_reader, tabular:)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      def each(&block)
        @line_reader.each { |line| @tabular.read_record_line(line, &block) }
      end

      # Writes each record to the writer, see `IOStreams::Record::Writer`, as a copy does, see
      # `IOStreams::Stream#copy_from`. A blank line, or a JSON line of null, which #each yields as nil, is not a record,
      # so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        each { |record| writer << record unless record.nil? }
      end
    end
  end
end
