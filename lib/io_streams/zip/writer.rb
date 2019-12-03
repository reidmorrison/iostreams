module IOStreams
  module Zip
    class Writer < IOStreams::Writer
      # Write a single file in Zip format to the supplied output stream
      #
      # Parameters
      #   output_stream [IO]
      #     Output stream to write to
      #
      #   original_file_name [String]
      #     Since this is a stream the original file name is used to create the entry_file_name if not supplied
      #
      #   entry_file_name: [String]
      #     Name of the file entry within the Zip file.
      #
      # The stream supplied to the block only responds to #write
      def self.stream(output_stream, original_file_name: nil, zip_file_name: nil, entry_file_name: zip_file_name, &block)
        # Default the name of the file within the zip to the supplied file_name without the zip extension
        if entry_file_name.nil? && original_file_name && (original_file_name =~ /\.(zip)\z/i)
          entry_file_name = original_file_name.to_s[0..-5]
        end
        entry_file_name ||= 'file'

        Utils.load_soft_dependency('zip_tricks', 'Zip') unless defined?(ZipTricks::Streamer)

        ZipTricks::Streamer.open(output_stream) { |zip| zip.write_deflated_file(entry_file_name, &block) }
      end
    end
  end
end
