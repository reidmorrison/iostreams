# frozen_string_literal: true

module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row, for `IOStreams::Stream#each(:hash)` and
    # `#reader(:hash)`, which create it with the tabular of the stream, whose options are documented with
    # `IOStreams::Tabular.new`.
    class Reader
      include Enumerable
      include IOStreams::Row::Numbered

      # Returns [Array<Symbol>] the options of each call that reads records, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Row::Reader.line_option_names`, whether to skip
      # the blank records, and the record that reading resumes at, see #initialize. The tabular that parses them takes
      # the settings of the path instead, such as its schema.
      def self.option_names
        [*IOStreams::Row::Reader.line_option_names, :skip_blanks, :resume_at, :on_invalid]
      end

      # Raises ArgumentError for a `skip_blanks` that is not true or false, or a `resume_at` that is neither nil nor a
      # positive Integer, see #initialize, or when nothing names the keys of the records that the tabular parses, see
      # `IOStreams::Tabular#check_records`, so that a call raises before the file is opened, see `IOStreams::Stream#each`.
      def self.check(tabular:, skip_blanks: false, resume_at: nil, on_invalid: nil)
        IOStreams::Utils.check_boolean(:skip_blanks, skip_blanks)
        IOStreams::Utils.check_record_number(:resume_at, resume_at)
        IOStreams::Row::Numbered.check_on_invalid(on_invalid)
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
      #   on_invalid: [#call|nil]
      #     Called with an `IOStreams::InvalidRow` for each record whose values are not all valid for their fields, which
      #     holds an error for each such field, rather than raise `IOStreams::Errors::InvalidValue` for the first, so that
      #     reading carries on with the next record, such as to list every bad row of an upload. The valid records are
      #     still yielded.
      #     Default: nil, which raises `IOStreams::Errors::InvalidValue`, naming the record and its line.
      #
      # Raises ArgumentError for options that cannot read records, see .check.
      def initialize(line_reader, tabular:, skip_blanks: false, resume_at: nil, on_invalid: nil)
        self.class.check(tabular: tabular, skip_blanks: skip_blanks, resume_at: resume_at, on_invalid: on_invalid)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader
        @skip_blanks = skip_blanks
        @on_invalid  = on_invalid
        # The number of records before `resume_at`, which #each reads without parsing.
        @skip        = resume_at ? resume_at - 1 : 0
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      #
      # A blank record is yielded as nil, unless `skip_blanks` is true, which skips it, see #initialize. With `resume_at`,
      # the records start with that one, without parsing the records before it: a line is a record once the tabular no
      # longer expects the header row, see `IOStreams::Tabular#header?`. A value that is not valid raises
      # `IOStreams::Errors::InvalidValue`, naming its record and line, unless `on_invalid:` takes the record, see
      # `IOStreams::Row::Numbered#invalid`.
      #
      # Returns an Enumerator of the records without a block.
      def each
        return enum_for(:each) unless block_given?

        skip    = @skip
        records = 0
        # Whether the header row is read, or the file has none, after which every line is a record.
        started = false
        each_numbered do |line, line_number, record_number|
          unless started
            if @tabular.header?
              @tabular.read_record_line(line) { nil }
              next
            end
            started = true
          end

          records += 1
          if skip.positive?
            skip -= 1
            next
          end

          begin
            record = @tabular.record_parse(line)
          rescue IOStreams::Errors::InvalidValue => e
            next invalid(e, line, line_number, record_number || records)
          end
          yield(record) unless @skip_blanks && record.nil?
        end
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
