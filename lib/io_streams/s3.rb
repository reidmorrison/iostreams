require 'uri'
module IOStreams
  module S3
    autoload :Reader, 'io_streams/s3/reader'
    autoload :Writer, 'io_streams/s3/writer'

    # Sample URI: s3://mybucket/user/abc.zip
    def self.parse_uri(uri)
      uri = URI.parse(uri)
      raise "Invalid URI. Required Format: 's3://<bucket_name>/<key>'" unless uri.scheme == 's3'
      {
        bucket: uri.host,
        key:    uri.path.sub(/\A\//, '')
      }
    end

    def self.load_dependencies
      return if defined?(::Aws::S3::Resource)

      require 'aws-sdk-s3'
    rescue LoadError => exc
      raise(LoadError, "Install gem 'aws-sdk-s3' to read and write AWS S3 files: #{exc.message}")
    end
  end
end
