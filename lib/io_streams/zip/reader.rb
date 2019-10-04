module IOStreams
  module Zip
    class Reader < IOStreams::Reader
      # Read from a zip file or stream, decompressing the contents as it is read
      # The input stream from the first file found in the zip file is passed
      # to the supplied block.
      #
      # Parameters:
      #   entry_file_name: [String]
      #     Name of the file within the Zip file to read.
      #     Default: Read the first file found in the zip file.
      #
      # Example:
      #   IOStreams::Zip::Reader.open('abc.zip') do |io_stream|
      #     # Read 256 bytes at a time
      #     while data = io_stream.read(256)
      #       puts data
      #     end
      #   end
      def self.open(file_name_or_io, entry_file_name: nil, &block)
        # File name supplied
        return read_file(file_name_or_io, entry_file_name, &block) unless IOStreams.reader_stream?(file_name_or_io)

        # Ruby ZIP gem uses `#seek` so can only work against a file, not a stream, so create temp file.
        # JRuby ZIP requires an InputStream.
        IOStreams::File::Path.temp_file_name('iostreams_zip') do |temp_file_name|
          IOStreams.copy(file_name_or_io, temp_file_name, target_options: {streams: []})
          read_file(temp_file_name, entry_file_name, &block)
        end
      end

      if defined?(JRuby)
        # Java has built-in support for Zip files
        def self.read_file(file_name, entry_file_name)
          fin = Java::JavaIo::FileInputStream.new(file_name)
          zin = Java::JavaUtilZip::ZipInputStream.new(fin)

          get_entry(zin, entry_file_name) ||
            raise(Java::JavaUtilZip::ZipException.new("File #{entry_file_name} not found within zip file."))

          yield(zin.to_io)
        ensure
          zin.close if zin
          fin.close if fin
        end

      else
        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        def self.read_file(file_name, entry_file_name)
          if !defined?(::Zip)
            # MRI needs Ruby Zip, since it only has native support for GZip
            begin
              require 'zip'
            rescue LoadError => exc
              raise(LoadError, "Install gem 'rubyzip' to read and write Zip files: #{exc.message}")
            end
          end

          ::Zip::InputStream.open(file_name) do |zin|
            get_entry(zin, entry_file_name) ||
              raise(::Zip::EntryNameError, "File #{entry_file_name} not found within zip file.")
            yield(zin)
          end
        end
      end

      def self.get_entry(zin, entry_file_name)
        if entry_file_name.nil?
          zin.get_next_entry
          return true
        end

        while entry = zin.get_next_entry
          return true if entry.name == entry_file_name
        end
        false
      end
    end
  end
end
