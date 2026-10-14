# frozen_string_literal: true

require "zlib"

module IOStreams
  module Zip
    class Reader < IOStreams::Reader
      def self.option_names
        %i[entry_file_name]
      end

      # Returns [Zip::Error] the error of rubyzip with the supplied message, so that a zip file that cannot be read
      # raises the same error on every platform. JRuby reads zip files with `java.util.zip`, so it only loads rubyzip
      # for this error.
      def self.error(message)
        Utils.load_soft_dependency("rubyzip", "Zip", "zip") unless defined?(::Zip::Error)
        ::Zip::Error.new(message)
      end

      # Returns [String] the message for a zip file that does not contain the file to read.
      def self.missing_message(entry_file_name, file_name)
        if entry_file_name
          "The zip file #{file_name} does not contain the file #{entry_file_name.inspect}"
        else
          "The zip file #{file_name} does not contain a file"
        end
      end

      # Returns [String] the message for a file within a zip file whose data is corrupt, for the supplied reason.
      def self.corrupt_message(entry_name, file_name, reason)
        "The file #{entry_name.inspect} within the zip file #{file_name} is corrupt: #{reason}"
      end

      # Read from a zip file or stream, decompressing the contents as it is read
      # The input stream from the first file found in the zip file, skipping any folders,
      # is passed to the supplied block.
      #
      # Parameters:
      #   entry_file_name: [String]
      #     Name of the file within the Zip file to read.
      #     Default: Read the first file found in the zip file.
      #
      # The stream supplied to the block responds to #read, #readpartial and #eof?, see `IOStreams::ChunkReader`.
      #
      # Raises [Zip::Error] when the zip file does not contain the file to read, or does not contain a file at all,
      # such as one of only folders, and once the whole file has been read, when its data is corrupt: its size, or its
      # CRC32, is not the one that the zip file records.
      #
      # Example:
      #   IOStreams::Zip::Reader.open('abc.zip') do |io_stream|
      #     # Read 256 bytes at a time
      #     while data = io_stream.read(256)
      #       puts data
      #     end
      #   end
      if defined?(JRuby)
        # Java has built-in support for Zip files, which checks the size and CRC32 of each file.
        def self.file(file_name, entry_file_name: nil)
          fin   = Java::JavaIo::FileInputStream.new(file_name)
          zin   = Java::JavaUtilZip::ZipInputStream.new(fin)
          entry = find_entry(zin, entry_file_name, file_name)
          yield Entry.new(zin, entry.name, file_name)
        ensure
          zin&.close
          fin&.close
        end

        # Returns the entry of the file to read, skipping any folders. Raises when the zip file does not contain it, or
        # when a file before it is corrupt, which `java.util.zip` finds as it reads past it.
        def self.find_entry(zin, entry_file_name, file_name)
          while (entry = zin.get_next_entry)
            return entry if !entry.directory? && (entry_file_name.nil? || entry.name == entry_file_name)
          end
          raise(error(missing_message(entry_file_name, file_name)))
        rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
          raise(error("The zip file #{file_name} is corrupt: #{e.message}"))
        end

        # Reads a file within a zip file from `java.util.zip`, a block at a time, like an IO.
        class Entry
          include ChunkReader

          BLOCK_SIZE = 65_536

          def initialize(zin, entry_name, file_name)
            @zin        = zin
            @entry_name = entry_name
            @file_name  = file_name
            @buffer     = Java::byte[BLOCK_SIZE].new
          end

          def closed?
            false
          end

          private

          # Returns [String] the next block of the file, or nil at its end, see `IOStreams::ChunkReader`.
          #
          # Raises [Zip::Error] for a file whose data is corrupt, with the reason that `java.util.zip` gives, which
          # a Ruby IO of the stream raises as `SystemCallError: Unknown error`.
          def next_chunk
            count = @zin.read(@buffer, 0, BLOCK_SIZE)
            return if count.negative?

            String.from_java_bytes(Java::JavaUtil::Arrays.copy_of_range(@buffer, 0, count))
          rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
            raise(Reader.error(Reader.corrupt_message(@entry_name, @file_name, e.message)))
          end
        end
      else
        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        def self.file(file_name, entry_file_name: nil, &block)
          Utils.load_soft_dependency("rubyzip", "Zip", "zip") unless defined?(::Zip::File)

          ::Zip::File.open(file_name) do |zip_file|
            entry = find_entry(zip_file, entry_file_name) || raise(error(missing_message(entry_file_name, file_name)))
            entry.get_input_stream { |input| block.call(Entry.new(input, entry, file_name)) }
          end
        end

        # Returns [Zip::Entry] the entry of the file to read, skipping any folders, or nil when there is none.
        def self.find_entry(zip_file, entry_file_name)
          return zip_file.find(&:file?) if entry_file_name.nil?

          entry = zip_file.find_entry(entry_file_name)
          entry if entry&.file?
        end

        # Reads a file within a zip file from rubyzip a block at a time, like an IO, see `IOStreams::BlockReader`.
        #
        # Checks the size and the CRC32 of the file once all of it has been read, since rubyzip does not, so that a
        # corrupt file raises, rather than returning the wrong data.
        class Entry < BlockReader
          def initialize(input, entry, file_name)
            super(input)
            @entry     = entry
            @file_name = file_name
            @crc       = Zlib.crc32
            @size      = 0
          end

          private

          def next_chunk
            chunk = super
            if chunk
              @crc   = Zlib.crc32(chunk, @crc)
              @size += chunk.bytesize
            else
              check
            end
            chunk
          end

          # Raises [Zip::Error] unless the data read has the size and the CRC32 of the file, giving the reason the way
          # that `java.util.zip` gives it on JRuby.
          def check
            if @size != @entry.size
              corrupt("invalid entry size (expected #{@entry.size} but got #{@size} bytes)")
            elsif @crc != @entry.crc
              corrupt(format("invalid entry CRC (expected 0x%<expected>x but got 0x%<actual>x)",
                             expected: @entry.crc, actual: @crc))
            end
          end

          def corrupt(reason)
            raise(Reader.error(Reader.corrupt_message(@entry.name, @file_name, reason)))
          end
        end
      end
    end
  end
end
