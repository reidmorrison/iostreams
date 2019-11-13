module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      # Write a single file in Zip format to the supplied output file name
      #
      # Parameters
      #   file_name [String]
      #     Full path and filename for the output zip file.
      #
      #   entry_file_name: [String]
      #     Name of the file entry within the Zip file.
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
      def self.file(file_name, original_file_name: file_name, zip_file_name: nil, entry_file_name: zip_file_name, &block)
        # Default the name of the file within the zip to the supplied file_name without the zip extension
        if entry_file_name.nil? && (original_file_name =~ /\.(zip)\z/i)
          entry_file_name = original_file_name.to_s[0..-5]
        end
        entry_file_name ||= 'file'

        write_file(file_name, entry_file_name, &block)
      end

      private

      if defined?(JRuby)
        def self.write_file(file_name, entry_file_name)
          out  = Java::JavaIo::FileOutputStream.new(file_name)
          zout = Java::JavaUtilZip::ZipOutputStream.new(out)
          zout.put_next_entry(Java::JavaUtilZip::ZipEntry.new(entry_file_name))
          io = zout.to_io
          yield(io)
        ensure
          io&.close
          out&.close
        end
      else
        def self.write_file(file_name, entry_file_name)
          Utils.load_soft_dependency('rubyzip', 'Zip', 'zip') unless defined?(::Zip)

          zos = ::Zip::OutputStream.new(file_name)
          zos.put_next_entry(entry_file_name)
          yield(zos)
        ensure
          zos&.close
        end
      end
    end
  end
end
