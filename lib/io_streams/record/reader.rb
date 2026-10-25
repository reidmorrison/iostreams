# frozen_string_literal: true

module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row, for `IOStreams::Stream#each(:hash)` and
    # `#reader(:hash)`, which create it with the tabular of the stream, whose options are documented with
    # `IOStreams::Tabular.new`.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads records, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Row::Reader.line_option_names`, whether to skip
      # the blank records, and the record that reading resumes at, see #initialize. The tabular that parses them takes
      # the settings of the path instead, such as its schema.
      def self.option_names
        [*IOStreams::Row::Reader.line_option_names, :skip_blanks, :resume_at]
      end

      # Raises ArgumentError for a `skip_blanks` that is not true or false, or a `resume_at` that is neither nil nor a
      # positive Integer, see #initialize, or when nothing names the keys of the records that the tabular parses, see
      # `IOStreams::Tabular#check_records`, so that a call raises before the file is opened, see `IOStreams::Stream#each`.
      def self.check(tabular:, skip_blanks: false, resume_at: nil)
        IOStreams::Utils.check_boolean(:skip_blanks, skip_blanks)
        IOStreams::Utils.check_record_number(:resume_at, resume_at)
        tabular.check_records
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
      #
      #   resume_at: [Integer|nil]
      #     The number of the record that reading resumes at, so that #each yields the records from it on, such as to
      #     resume the work of a job that processed the records before it. Records are counted as the slices of the
      #     file number them, see `IOStreams::Slice#record_number_at`: from 1, without the header row, nor the blank
      #     lines before it, so that a blank record after it counts. The lines of the records before it are read, but
      #     not parsed.
      #     Default: nil, every record
      #
      # Raises ArgumentError for options that cannot read records, see .check.
      def initialize(line_reader, tabular:, skip_blanks: false, resume_at: nil)
        self.class.check(tabular: tabular, skip_blanks: skip_blanks, resume_at: resume_at)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader
        @skip_blanks = skip_blanks
        # The number of records before `resume_at`, which #each reads without parsing.
        @skip        = resume_at ? resume_at - 1 : 0
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      #
      # A blank record is yielded as nil, unless `skip_blanks` is true, which skips it, see #initialize. With `resume_at`,
      # the records start with that one, see #initialize.
      #
      # Returns an Enumerator of the records without a block.
      def each(&block)
        return enum_for(:each) unless block
        return each_resumed(&block) if @skip.positive?
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

      private

      # Yields the records from `resume_at` on, see #initialize, without parsing the records before it: a line is a
      # record once the tabular no longer expects the header row, see `IOStreams::Tabular#header?`.
      def each_resumed
        skip = @skip
        @line_reader.each do |line|
          if skip.positive? && !@tabular.header?
            skip -= 1
          else
            @tabular.read_record_line(line) { |record| yield(record) unless @skip_blanks && record.nil? }
          end
        end
      end
    end
  end
end
