module IOStreams
  module S3
    class Writer
      # Write to AWS S3
      def self.open(uri, region: nil, **args, &block)
        raise(ArgumentError, 'file_name must be a URI string') unless uri.is_a?(String)

        IOStreams::S3.load_dependencies

        options = IOStreams::S3.parse_uri(uri)
        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        object  = s3.bucket(options[:bucket]).object(options[:key])
        object.upload_stream(args, &block)
      end
    end
  end
end
