module RocketJob
  module Streams
    class ZipReader
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
        def self.open(file_name_or_io, _=nil, &block)
          fin = file_name_or_io.respond_to?(:read) ? file_name_or_io.to_inputstream : Java::JavaIo::FileInputStream.new(file_name_or_io)
          zin = Java::JavaUtilZip::ZipInputStream.new(fin)
          entry = zin.get_next_entry
          block.call(zin.to_io,
            { name: entry.name, compressed_size: entry.compressed_size, time: entry.time, size: entry.size, comment: entry.comment })
        ensure
          zin.close if zin
          fin.close if fin && !file_name_or_io.respond_to?(:read)
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
        def self.open(file_name_or_io, _=nil, &block)
          unless file_name_or_io.respond_to?(:read)
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

      end
    end
  end
end