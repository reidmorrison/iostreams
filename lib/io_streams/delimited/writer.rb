module IOStreams
  module Delimited
    class Writer
      attr_accessor :delimiter

      # Write delimited records/lines to a file or stream
      def self.open(file_name_or_io, options={}, &block)
        if IOStreams.writer_stream?(file_name_or_io)
          block.call(new(file_name_or_io, options))
        else
          ::File.open(file_name_or_io, 'wb') do |io|
            block.call(new(io, options))
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
      #   options
      #     delimiter: [String]
      #       Add the specified delimiter after every record when writing it
      #       to the output stream
      #       Default: OS Specific. Linux: "\n"
      #
      #     :encoding
      #       Force encoding to this encoding for all data being read
      #       Default: UTF8_ENCODING
      #       Set to nil to disable encoding
      #
      #     :strip_non_printable [true|false]
      #       Strip all non-printable characters read from the file
      #       Default: false
      def initialize(output_stream, options={})
        @output_stream       = output_stream
        options              = options.dup
        @delimiter           = options.has_key?(:delimiter) ? options.delete(:delimiter) : $/.dup
        @encoding            = options.has_key?(:encoding) ? options.delete(:encoding) : UTF8_ENCODING
        @strip_non_printable = options.delete(:strip_non_printable)
        @strip_non_printable = @strip_non_printable.nil? && (@encoding == UTF8_ENCODING)
        raise ArgumentError.new("Unknown IOStreams::Delimited::Writer#initialize options: #{options.inspect}") if options.size > 0
        @delimiter.force_encoding(UTF8_ENCODING) if @delimiter
      end

      # Write a record or line to the output stream
      def <<(record)
        chunk = record.to_s
        # Strip out non-printable characters before converting to UTF-8
        chunk = chunk.gsub(NOT_PRINTABLE, '') if @strip_non_printable
        @output_stream.write((@encoding ? chunk.force_encoding(@encoding) : chunk))
        @output_stream.write(@delimiter)
      end

      # Write the given string to the underlying stream
      # Note: Use of this method not recommended
      def write(string)
        @output_stream.write(string)
      end

    end
  end
end
