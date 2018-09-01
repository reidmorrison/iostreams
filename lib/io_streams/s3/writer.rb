module IOStreams
  module S3
    class Writer
      # Write to AWS S3
      def self.open(uri = nil, bucket: nil, region: nil, key: nil, &block)
        options = uri.nil? ? args : parse_uri(uri).merge(args)
        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        object  = s3.bucket(options[:bucket]).object(options[:key])
        object.upload_stream(file_name_or_io, &block)
      end
    end
  end
end
