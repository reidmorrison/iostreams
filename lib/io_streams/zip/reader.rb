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
      if defined?(JRuby)
        # Java has built-in support for Zip files
        def self.file(file_name, entry_file_name: nil)
          fin = Java::JavaIo::FileInputStream.new(file_name)
          zin = Java::JavaUtilZip::ZipInputStream.new(fin)

          get_entry(zin, entry_file_name) ||
            raise(Java::JavaUtilZip::ZipException, "File #{entry_file_name} not found within zip file.")

          yield(zin.to_io)
        ensure
          zin&.close
          fin&.close
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
      else
        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        def self.file(file_name, entry_file_name: nil, &block)
          Utils.load_soft_dependency('rubyzip v1.x', 'Read Zip', 'zip') unless defined?(::Zip)

          ::Zip::File.open(file_name) do |zip_file|
            if entry_file_name
              zip_file.get_input_stream(entry_file_name, &block)
            else
              result = nil
              # Return the first file
              zip_file.each do |entry|
                result = entry.get_input_stream(&block)
                break
              end
              result
            end
          end
        end
      end
    end
  end
end
