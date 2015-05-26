module RocketJob
  module Streams
    class Zip
      if defined?(JRuby)
        # Java has built-in support for Zip files
        # https://github.com/jruby/jruby/wiki/CallingJavaFromJRuby

        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        #
        # Example:
        #   RocketJob::Reader::Zip.read('abc.zip') do |io_stream, source|
        #     # Display header info
        #     puts source.inspect
        #
        #     # Read 256 bytes at a time
        #     while data = io_stream.read(256)
        #       puts data
        #     end
        #   end
        #
        # Example:
        #   File.open('myfile.zip') do |io|
        #     RocketJob::Reader::Zip.input_stream(io) do |io_stream, source|
        #       # Display header info
        #       puts source.inspect
        #
        #       # Read 256 bytes at a time
        #       while data = io_stream.read(256)
        #         puts data
        #       end
        #     end
        #   end
        #
        # Note: The stream currently only supports #read
        def read(file_name_or_io, &block)
          fin = file_name_or_io.is_a?(String) ? Java::JavaIo::FileInputStream.new(file_name_or_io) : file_name_or_io.to_inputstream
          zin = Java::JavaUtilZip::ZipInputStream.new(fin)
          entry = zin.get_next_entry
          block.call(zin.to_io,
            { name: entry.name, compressed_size: entry.compressed_size, time: entry.time, size: entry.size, comment: entry.comment })
        ensure
          zin.close if zin
          fin.close if fin && file_name_or_io.is_a?(String)
        end

        def write_file(zip_file_name, file_name, &block)
          out  = Java::JavaIo::FileOutputStream.new(file_name)
          zout = Java::JavaUtilZip::ZipOutputStream.new(out)
          zout.put_next_entry(Java::JavaUtilZip::ZipEntry.new(zip_file_name))
          io = zout.to_io
          block.call(io)
        ensure
          io.close if io
          out.close if out
        end

      else
        # MRI needs Ruby Zip, since it only has native support for GZip
        begin
          require 'zip'
        rescue LoadError => exc
          puts "Please install gem rubyzip so that RocketJob can read Zip files in Ruby MRI"
          raise(exc)
        end

        # Read from a zip file or stream, decompressing the contents as it is read
        # The input stream from the first file found in the zip file is passed
        # to the supplied block
        def read(file_name_or_io, &block)
          if file_name_or_io.is_a?(String)
            ::Zip::File.open(file_name_or_io) do |zip_file|
              raise 'The zip archive did not have any files in it.' if zip_file.count == 0
              raise 'The zip archive has more than one file in it.' if zip_file.count != 1
              entry = zip_file.first
              entry.get_input_stream do |io_stream|
                if block.arity == 1
                  block.call(io_stream)
                else
                  block.call(io_stream,
                    { name: entry.name, compressed_size: entry.compressed_size, time: entry.time, size: entry.size, comment: entry.comment })
                end
              end
            end
          else
            begin
              zin = ::Zip::InputStream.new(file_name_or_io)
              entry = zin.get_next_entry
              if block.arity == 1
                block.call(zin)
              else
                block.call(zin,
                  { name: entry.name, compressed_size: entry.compressed_size, time: entry.time, size: entry.size, comment: entry.comment })
              end
            ensure
              zin.close if zin
            end
          end
        end

        def write_file(zip_file_name, file_name, &block)
          zos = ::Zip::OutputStream.new(zip_file_name)
          zos.put_next_entry(file_name)
          block.call(zos)
        ensure
          zos.close_buffer if zos
        end

      end

      # Options to be passed into this Zip stream
      def initialize(options={})
        @zip_file_name = options.delete(:zip_filename) || 'file'
        @buffer_size   = options.delete(:buffer_size) || 65536
      end

      # Note:
      #   Cannot stream into a ZIP formatted file since it needs to re-wind
      #   to the beginning to update the header after adding any files.

      # Write a single file in Zip format to the supplied output file name
      #
      # Parameters
      #   zip_file_name [String]
      #     Full path and filename for the output zip file
      #
      #   file_name [String]
      #     Name of the file within the Zip Stream
      #
      # The stream supplied to the block only responds to #write
      #
      # Example:
      #   RocketJob::Writer::Zip.open_file('myfile.zip', 'hello.txt') do |io_stream|
      #     io_stream.write("hello world\n")
      #     io_stream.write("and more\n")
      #   end

      # Write to a file or stream, compressing with zip
      #
      # Notes:
      # - Since Zip cannot write to streams, if a stream is supplied, a
      #
      #
      def write(file_name_or_io, &block)
        temp_file     = nil
        file_name     = if file_name_or_io.is_a?(String)
          file_name_or_io
        else
          # Since ZIP cannot be streamed, download to a local file before streaming
          temp_file = Tempfile.new('rocket_job')
          temp_file.to_path
        end

        write_file(@zip_file_name, file_name, &block)

        if temp_file
          # Stream temp file into output stream
          File.open(fout, 'rb') do |file|
            while chunk = file.read(@buffer_size)
              file_name_or_io.write(chunk)
            end
          end
        end
      ensure
        temp_file.delete if temp_file
      end

    end
  end
end