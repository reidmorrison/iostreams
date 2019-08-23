module IOStreams
  module S3
    class Reader
      # Read from a AWS S3 file
      def self.open(uri, region: nil, **args, &block)
        raise(ArgumentError, 'file_name must be a URI string') unless uri.is_a?(String)

        IOStreams::S3.load_dependencies

        # https://aws.amazon.com/blogs/developer/using-resources/
        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        options = IOStreams::S3.parse_uri(uri)
        object  = s3.bucket(options[:bucket]).object(options[:key])

        begin
          # Since S3 download only supports a push stream, write it to a tempfile first.
          IOStreams::File::Path.temp_file_name('iostreams_s3') do |file_name|
            args[:response_target] = file_name
            object.get(args)

            # Return a read stream
            IOStreams::File::Reader.open(file_name, &block)
          end
        end
      end
    end
  end
end
