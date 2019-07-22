module IOStreams
  module S3
    class Reader
      # Read from a AWS S3 file
      def self.open(uri, region: nil, **args, &block)
        raise(ArgumentError, 'file_name must be a URI string') unless uri.is_a?(String)

        IOStreams::S3.load_dependencies

        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        options = IOStreams::S3.parse_uri(uri)
        object  = s3.bucket(options[:bucket]).object(options[:key])

        begin
          # Since S3 download only supports a push stream, write it to a tempfile first.
          temp_file = Tempfile.new('rocket_job')
          temp_file.binmode

          args[:response_target] = temp_file.to_path
          object.get(args)

          block.call(temp_file)
        ensure
          temp_file.delete if temp_file
        end
      end
    end
  end
end
