module IOStreams
  module S3
    class Writer
      # Write to AWS S3
      #
      # Arguments:
      #
      # uri: [String]
      #   Prefix must be: `s3://`
      #   followed by bucket name,
      #   followed by path and file_name (key).
      #   Examples:
      #     s3://my-bucket-name/file_name.txt
      #     s3://my-bucket-name/some_path/file_name.csv
      #
      # region: [String]
      #   AWS Region.
      #   Default: ENV['AWS_REGION'], or supplied by ruby driver
      #
      # thread_count: [Integer]
      #   The number of parallel multipart uploads
      #   Default: 10
      #
      # tempfile: [Boolean]
      #   Normally read data is stored in memory when building the parts in order to complete
      #   the underlying multipart upload. By passing `:tempfile => true` data read will be
      #   temporarily stored on disk reducing the memory footprint vastly.
      #   Default: false
      #
      # part_size: [Integer]
      #   Define how big each part size but the last should be.
      #   Default: 5 * 1024 * 1024
      #
      # Other possible options extracted from AWS source code:
      #   # See: https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html#create_multipart_upload-instance_method
      #
      #   acl: "private", # accepts private, public-read, public-read-write, authenticated-read, aws-exec-read, bucket-owner-read, bucket-owner-full-control
      #   cache_control: "CacheControl",
      #   content_disposition: "ContentDisposition",
      #   content_encoding: "ContentEncoding",
      #   content_language: "ContentLanguage",
      #   content_type: "ContentType",
      #   expires: Time.now,
      #   grant_full_control: "GrantFullControl",
      #   grant_read: "GrantRead",
      #   grant_read_acp: "GrantReadACP",
      #   grant_write_acp: "GrantWriteACP",
      #   metadata: {
      #     "MetadataKey" => "MetadataValue",
      #   },
      #   server_side_encryption: "AES256", # accepts AES256, aws:kms
      #   storage_class: "STANDARD", # accepts STANDARD, REDUCED_REDUNDANCY, STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER, DEEP_ARCHIVE
      #   website_redirect_location: "WebsiteRedirectLocation",
      #   sse_customer_algorithm: "SSECustomerAlgorithm",
      #   sse_customer_key: "SSECustomerKey",
      #   sse_customer_key_md5: "SSECustomerKeyMD5",
      #   ssekms_key_id: "SSEKMSKeyId",
      #   ssekms_encryption_context: "SSEKMSEncryptionContext",
      #   request_payer: "requester", # accepts requester
      #   tagging: "TaggingHeader",
      #   object_lock_mode: "GOVERNANCE", # accepts GOVERNANCE, COMPLIANCE
      #   object_lock_retain_until_date: Time.now,
      #   object_lock_legal_hold_status: "ON", # accepts ON, OFF
      #
      # Raises [MultipartUploadError] If an object is being uploaded in
      #   parts, and the upload can not be completed, then the upload is
      #   aborted and this error is raised.  The raised error has a `#errors`
      #   method that returns the failures that caused the upload to be
      #   aborted.
      def self.open(uri, region: nil, **args)
        raise(ArgumentError, 'file_name must be a URI string') unless uri.is_a?(String)

        IOStreams::S3.load_dependencies

        options = IOStreams::S3.parse_uri(uri)
        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        object  = s3.bucket(options[:bucket]).object(options[:key])
        object.upload_stream(args) do |s3|
          s3.binmode
          yield(s3)
        end
      end
    end
  end
end
