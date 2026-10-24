# frozen_string_literal: true

module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row, for `IOStreams::Stream#each(:hash)` and
    # `#reader(:hash)`, which create it with the tabular of the stream, whose options are documented with
    # `IOStreams::Tabular.new`.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads records, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Row::Reader.line_option_names`, and whether to
      # skip the blank records, see #initialize. The tabular that parses them takes the settings of the path instead,
      # such as its schema.
      def self.option_names
        [*IOStreams::Row::Reader.line_option_names, :skip_blanks]
      end

      # Raises ArgumentError for a `skip_blanks` that is not true or false, see #initialize, so that a call raises before
      # the file is opened, see `IOStreams::Stream#each`.
      def self.check(skip_blanks: false)
        IOStreams::Utils.check_boolean(:skip_blanks, skip_blanks)
      end

      # Create a reader to return the stream as Hash records.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, and holds the header, see `IOStreams::Tabular#read_record_line`.
      #
      #   skip_blanks: [true|false]
      #     Whether #each skips each blank record, rather than yield nil for it: a line that is empty or only whitespace,
      #     or a record whose every value is nil or blank text, such as a line of CSV of only commas, or a JSON record of
      #     null, see `IOStreams::Tabular#blank?`. Keep the default to count the lines of the file from the records
      #     yielded, after the header row, such as to report the line of a record that is not valid.
      #     Default: false
      def initialize(line_reader, tabular:, skip_blanks: false)
        self.class.check(skip_blanks: skip_blanks)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader
        @skip_blanks = skip_blanks
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      #
      # A blank record is yielded as nil, unless `skip_blanks` is true, which skips it, see #initialize.
      #
      # Returns an Enumerator of the records without a block.
      def each(&block)
        return enum_for(:each) unless block
        return @line_reader.each { |line| @tabular.read_record_line(line, &block) } unless @skip_blanks

        @line_reader.each { |line| @tabular.read_record_line(line) { |record| yield record unless record.nil? } }
      end

      # Writes each record to the writer, see `IOStreams::Record::Writer`, as a copy does, see
      # `IOStreams::Stream#copy_from`. A blank line, or a JSON line of null, which #each yields as nil, is not a record,
      # so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        each { |record| writer << record unless record.nil? }
      end

      # Returns [String] the class and the format of the records, see `IOStreams::Tabular#format`, rather than every
      # instance variable, such as the tabular and the lines that it reads, so that irb, which displays what a reader
      # block returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end
    end
  end
end
