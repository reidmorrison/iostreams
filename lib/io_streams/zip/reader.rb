module IOStreams
  module Zip
    class Reader
      # Read from a zip file or stream, decompressing the contents as it is read
      # The input stream from the first file found in the zip file is passed
      # to the supplied block
      #
      # Example:
      #   IOStreams::Zip::Reader.open('abc.zip') do |io_stream|
      #     # Read 256 bytes at a time
      #     while data = io_stream.read(256)
      #       puts data
      #     end
      #   end
      def self.open(file_name_or_io, buffer_size: 65536, &block)
        if !defined?(JRuby) && !defined?(::Zip)
          # MRI needs Ruby Zip, since it only has native support for GZip
          begin
            require 'zip'
          rescue LoadError => exc
            raise(LoadError, "Install gem 'rubyzip' to read and write Zip files: #{exc.message}")
          end
        end

        # File name supplied
        return read_file(file_name_or_io, &block) unless IOStreams.reader_stream?(file_name_or_io)

        # Stream supplied
        begin
          # Since ZIP cannot be streamed, download un-zipped data to a local file before streaming
          temp_file = Tempfile.new('rocket_job')
          temp_file.binmode
          file_name = temp_file.to_path

          # Stream zip stream into temp file
          ::File.open(file_name, 'wb') do |file|
            IOStreams.copy(file_name_or_io, file, buffer_size: buffer_size)
          end

          read_file(file_name, &block)
        ensure
          temp_file.delete if temp_file
        end
      end

      if defined?(JRuby)
        # Java has built-in support for Zip files
        def self.read_file(file_name, &block)
          fin = Java::JavaIo::FileInputStream.new(file_name)
          zin = Java::JavaUtilZip::ZipInputStream.new(fin)
          zin.get_next_entry
          block.call(zin.to_io)
        ensure
          zin.close if zin
          fin.close if fin
        end

      else

        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        def self.read_file(file_name, &block)
          begin
            zin = ::Zip::InputStream.new(file_name)
            zin.get_next_entry
            block.call(zin)
          ensure
            begin
              zin.close if zin
            rescue IOError
              # Ignore file already closed errors since Zip::InputStream
              # does not have a #closed? method
            end
          end
        end

      end
    end
  end
end
