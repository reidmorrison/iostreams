module IOStreams
  module Zip
    class Writer
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
      #   IOStreams::ZipWriter.open('myfile.zip', zip_file_name: 'myfile.txt') do |io_stream|
      #     io_stream.write("hello world\n")
      #     io_stream.write("and more\n")
      #   end
      #
      # Notes:
      # - Since Zip cannot write to streams, if a stream is supplied, a temp file
      #   is automatically created under the covers
      def self.open(file_name_or_io, options={}, &block)
        options       = options.dup
        zip_file_name = options.delete(:zip_file_name)
        buffer_size   = options.delete(:buffer_size) || 65536
        raise(ArgumentError, "Unknown IOStreams::Zip::Writer option: #{options.inspect}") if options.size > 0

        # Default the name of the file within the zip to the supplied file_name without the zip extension
        zip_file_name = file_name_or_io.to_s[0..-5] if zip_file_name.nil? && !file_name_or_io.respond_to?(:write) && (file_name_or_io =~ /\.(zip)\z/)
        zip_file_name ||= 'file'

        # File name supplied
        return write_file(file_name_or_io, zip_file_name, &block) unless file_name_or_io.respond_to?(:write)

        # Stream supplied
        begin
          # Since ZIP cannot be streamed, download to a local file before streaming
          temp_file = Tempfile.new('rocket_job')
          write_file(temp_file.to_path, zip_file_name, &block)

          # Stream temp file into output stream
          IOStreams.copy(temp_file, file_name_or_io, buffer_size)
        ensure
          temp_file.delete if temp_file
        end
      end

      private

      if defined?(JRuby)

        def self.write_file(file_name, zip_file_name, &block)
          out  = Java::JavaIo::FileOutputStream.new(file_name)
          zout = Java::JavaUtilZip::ZipOutputStream.new(out)
          zout.put_next_entry(Java::JavaUtilZip::ZipEntry.new(zip_file_name))
          io = zout.to_io
          block.call(io)
        ensure
          io.close if io && !io.closed?
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

        def self.write_file(file_name, zip_file_name, &block)
          zos = ::Zip::OutputStream.new(file_name)
          zos.put_next_entry(zip_file_name)
          block.call(zos)
        ensure
          zos.close if zos
        end

      end

    end
  end
end