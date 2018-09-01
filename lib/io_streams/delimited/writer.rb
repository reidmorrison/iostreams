module IOStreams
  module Delimited
    class Writer
      attr_accessor :delimiter

      # Write delimited records/lines to a file or stream
      def self.open(file_name_or_io, delimiter: $/, encoding: UTF8_ENCODING, strip_non_printable: false)
        if IOStreams.writer_stream?(file_name_or_io)
          yield new(file_name_or_io, delimiter: delimiter, encoding: encoding, strip_non_printable: strip_non_printable)
        else
          ::File.open(file_name_or_io, 'wb') do |io|
            yield new(io, delimiter: delimiter, encoding: encoding, strip_non_printable: strip_non_printable)
          end
        end
      end

      NOT_PRINTABLE = Regexp.compile(/[^[:print:]]/)

      # A delimited stream writer that will write to the supplied output stream
      #
      # The output stream should be binary with no text conversions performed
      # since `strip_non_printable` will be applied to the binary stream before
      # converting to UTF-8
      #
      # Parameters
      #   output_stream
      #     The output stream that implements #write
      #
      #   delimiter: [String]
      #     Add the specified delimiter after every record when writing it
      #     to the output stream
      #     Default: OS Specific. Linux: "\n"
      #
      #   encoding:
      #     Force encoding to this encoding for all data being read
      #     Default: UTF8_ENCODING
      #     Set to nil to disable encoding
      #
      #   strip_non_printable: [true|false]
      #     Strip all non-printable characters read from the file
      #     Default: false
      def initialize(output_stream, delimiter: $/, encoding: UTF8_ENCODING, strip_non_printable: false)
        @output_stream       = output_stream
        if delimiter
          @delimiter           = delimiter.dup
          @delimiter.force_encoding(UTF8_ENCODING)
        end
        @encoding            = encoding
        @strip_non_printable = strip_non_printable
      end

      # Write a record or line to the output stream
      def <<(record)
        chunk = record.to_s
        # Strip out non-printable characters before converting to UTF-8
        chunk = chunk.gsub(NOT_PRINTABLE, '') if @strip_non_printable
        @output_stream.write((@encoding ? chunk.force_encoding(@encoding) : chunk))
        @output_stream.write(@delimiter) if @delimiter
      end

      # Write the given string to the underlying stream
      # Note: Use of this method not recommended
      #
      #
      # TODO: Remove this method once there is another way to know if it is a writer stream
      def write(string)
        @output_stream.write(string)
      end

    end
  end
end
