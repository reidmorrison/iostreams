# frozen_string_literal: true

module IOStreams
  module Row
    # Names the row of each error of a row that cannot be read, see `IOStreams::Errors::RowError`, for the readers and
    # writers of rows, records and slices, and the parsers of the formats, which are its only callers, so that how it
    # does so is not part of the public interface.
    module Locator
      # Tags the supplied exception, which the gem reading a format raised for a row that it cannot read, as an
      # `IOStreams::Errors::RowError`, so that the reader of the rows names its record and line, see .locate, as for the
      # errors that IOStreams raises. The supplied reason is its message without the gem's own place within the text of
      # the row, such as "Illegal quoting" for the csv gem's "Illegal quoting in line 1.", since the line that it names
      # is that of the row, not of the file, which the message names instead once it is known, see
      # `IOStreams::Errors::RowError#reason`, or nil to keep its message.
      #
      # Returns [Exception] the exception. It is unchanged when it is frozen, or already a RowError.
      def self.tag(exception, reason = nil)
        return exception if exception.frozen? || exception.is_a?(IOStreams::Errors::RowError)

        reason ||= exception.message
        exception.extend(IOStreams::Errors::RowError)
        Reason.give(exception, reason)
      end

      # Returns the result of the supplied block, which reads a row, raising an `IOStreams::Errors::RowError` that it
      # raises at the supplied record and line, see `IOStreams::Errors::RowError#at`, or for a header row, which is not a
      # record, at its line only. The block reads the row and nothing else, never calling the block of the caller of a
      # reader, nor writing what it read, so that an error that they raise is not taken for one of the row.
      #
      # The path of each row of a reader or writer rescues the error itself instead, since the block costs each row more:
      # `IOStreams::Row::Reader#read_rows`, `IOStreams::Record::Reader#read_records`, `IOStreams::Slice::Collector#add`,
      # and the rows that `IOStreams::Slice::Writer` writes.
      def self.locate(line_number: nil, record_number: nil)
        yield
      rescue IOStreams::Errors::RowError => e
        raise e.at(line_number: line_number, record_number: record_number)
      end

      # The reason that the exception of a gem was tagged with, see .tag, which it answers in place of its message, see
      # `IOStreams::Errors::RowError#reason`.
      module Reason
        # Returns [Exception] the supplied exception, which answers the supplied reason.
        def self.give(exception, reason)
          exception.instance_variable_set(:@iostreams_reason, reason)
          exception.extend(self)
        end

        # Returns [String] the reason that the exception was tagged with.
        def reason
          @iostreams_reason
        end
      end
      private_constant :Reason
    end
  end
end
