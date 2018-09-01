begin
  require 'aws-sdk-s3'
rescue LoadError => exc
  raise(LoadError, "Install gem 'aws-sdk-s3' to read and write AWS S3 files: #{exc.message}")
end

require 'uri'
module IOStreams
  module S3
    # Sample URI: s3://mybucket/user/abc.zip
    def self.parse_uri(uri)
      # 's3://mybucket/user/abc.zip'
      uri = URI.parse(uri)
      # Filename and bucket only
      if uri.scheme.nil?
        segments = uri.path.split('/')
        raise "S3 URI must at the very least contain '<bucket_name>/<key>'" if (segments.size == 1) || (segments[0] == '')
        {
          bucket: segments.shift,
          key:    segments.join('/')
        }
      end
    end
  end
end
