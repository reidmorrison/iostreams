# frozen_string_literal: true

require "zlib"

module IOStreams
  module Zip
    class Reader < IOStreams::Reader
      def self.option_names
        %i[entry_file_name]
      end

      # Returns [Module] `IOStreams::Errors::Corrupt` for `Zip::Error`, which rubyzip raises for a file that is not a zip
      # file, data that it cannot decompress, or a part of the format that it does not support, such as a file
      # encrypted with a password, see `IOStreams::Reader.failure_kind`. Only MRI reads zip files with rubyzip.
      def self.failure_kind(exception)
        Errors::Corrupt if defined?(::Zip::Error) && exception.is_a?(::Zip::Error)
      end

      # Returns [IOStreams::Errors::StreamFailure] the failure with the supplied message, tagged with the supplied kind
      # of failure, such as `IOStreams::Errors::MissingEntry`, and the name of the zip file, for a failure that this
      # reader finds itself, so that it raises the same exception on every platform, whichever library reads the zip
      # file.
      def self.failure(kind, message, file_name)
        kind.tag(Errors::StreamFailure.new(message), file_name)
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
      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::MissingEntry` when the zip file does not
      # contain the file to read, or does not contain a file at all, such as one of only folders, and tagged as
      # `IOStreams::Errors::Corrupt` once the whole file has been read, when its data is corrupt: its size, or its
      # CRC32, is not the one that the zip file records. A file that is not a zip file, or data that cannot be
      # decompressed, also raises an exception tagged as `IOStreams::Errors::Corrupt`: rubyzip's `Zip::Error` on MRI,
      # and the StreamFailure on JRuby, which reads zip files with `java.util.zip`.
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
        #
        # `java.util.zip` finds no entries in a file that is not a zip file, rather than raising, so it is told apart
        # from a zip file without any entries by how it starts, see .empty_zip?.
        def self.find_entry(zin, entry_file_name, file_name)
          entries = false
          while (entry = zin.get_next_entry)
            entries = true
            return entry if !entry.directory? && (entry_file_name.nil? || entry.name == entry_file_name)
          end
          unless entries || empty_zip?(file_name)
            raise(failure(Errors::Corrupt, "The file #{file_name} is not a zip file", file_name))
          end

          raise(failure(Errors::MissingEntry, missing_message(entry_file_name, file_name), file_name))
        rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
          raise(failure(Errors::Corrupt, "The zip file #{file_name} is corrupt: #{e.message}", file_name))
        end

        # Returns [true|false] whether the file is a zip file without any entries, which holds only the end of its
        # central directory, and so starts with its signature.
        def self.empty_zip?(file_name)
          ::File.binread(file_name, 4) == "PK\x05\x06".b
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
          # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` for a file whose data is
          # corrupt, with the reason that `java.util.zip` gives, which a Ruby IO of the stream raises as
          # `SystemCallError: Unknown error`.
          def next_chunk
            count = @zin.read(@buffer, 0, BLOCK_SIZE)
            return if count.negative?

            String.from_java_bytes(Java::JavaUtil::Arrays.copy_of_range(@buffer, 0, count))
          rescue Java::JavaUtilZip::ZipException, Java::JavaIo::EOFException => e
            raise(Reader.failure(Errors::Corrupt, Reader.corrupt_message(@entry_name, @file_name, e.message), @file_name))
          end
        end
      else
        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        #
        # rubyzip is called within `.tag_failure`, but not the block, see `IOStreams::Reader.tag_failure`.
        def self.file(file_name, entry_file_name: nil, &block)
          Utils.load_soft_dependency("rubyzip", "Zip", "zip") unless defined?(::Zip::File)

          zip_file = tag_failure(file_name) { ::Zip::File.open(file_name) }
          entry    = find_entry(zip_file, entry_file_name)
          raise(failure(Errors::MissingEntry, missing_message(entry_file_name, file_name), file_name)) unless entry

          input = tag_failure(file_name) { entry.get_input_stream }
          begin
            block.call(Entry.new(input, entry, file_name))
          ensure
            input.close
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

          # Returns [String] the next block of the file, or nil at its end, see `IOStreams::ChunkReader`. Tags an
          # exception that rubyzip raises for data that it cannot decompress, see `Reader.failure_kind`, and checks the
          # file once all of it has been read, see #check.
          def next_chunk
            chunk = Reader.tag_failure(@file_name) { super }
            if chunk
              @crc   = Zlib.crc32(chunk, @crc)
              @size += chunk.bytesize
            else
              check
            end
            chunk
          end

          # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` unless the data read has the
          # size and the CRC32 of the file, giving the reason the way that `java.util.zip` gives it on JRuby.
          def check
            if @size != @entry.size
              corrupt("invalid entry size (expected #{@entry.size} but got #{@size} bytes)")
            elsif @crc != @entry.crc
              corrupt(format("invalid entry CRC (expected 0x%<expected>x but got 0x%<actual>x)",
                             expected: @entry.crc, actual: @crc))
            end
          end

          def corrupt(reason)
            raise(Reader.failure(Errors::Corrupt, Reader.corrupt_message(@entry.name, @file_name, reason), @file_name))
          end
        end
      end
    end
  end
end
