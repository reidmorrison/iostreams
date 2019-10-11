module IOStreams
  module Paths
    class S3 < IOStreams::Path
      attr_reader :bucket, :key, :s3, :region

      # Arguments:
      #
      # url: [String]
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
      # Writer specific options:
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
      def initialize(url, region: nil, **args)
        Utils.load_dependency('aws-sdk-s3', 'AWS S3') unless defined?(::Aws::S3::Resource)

        parse_url(url)

        # https://aws.amazon.com/blogs/developer/using-resources/
        @s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        @object  = s3.bucket(bucket).object(key)
        @region  = region
        @options = args
        super(url)
      end

      # S3 logically creates paths when a key is set.
      def mkpath
        self
      end

      def mkdir
        self
      end

      def exist?
        object.exists?
      end

      def size
        object.size
      end

      def delete
        object.delete
        self
      end

      # Read from AWS S3 file.
      def reader(**args, &block)
        # Since S3 download only supports a push stream, write it to a tempfile first.
        IOStreams::File::Path.temp_file_name('iostreams_s3') do |file_name|
          args[:response_target] = file_name
          object.get(args)

          # Return a read stream
          IOStreams::Paths::File.new(file_name).reader { |io| streams.reader(io, &block) }
        end
      end

      # Write to AWS S3
      #
      # Raises [MultipartUploadError] If an object is being uploaded in
      #   parts, and the upload can not be completed, then the upload is
      #   aborted and this error is raised.  The raised error has a `#errors`
      #   method that returns the failures that caused the upload to be
      #   aborted.
      def writer(&block)
        # S3 upload hangs with large files, write it to a tempfile first.
        IOStreams::Paths::File.temp_file_name('iostreams_s3') do |file_name|
          IOStreams::Paths::File.new(file_name).writer do |io|
            streams.reader(io) do
              # TODO: copy
            end
          end
        end
        # TODO: Use this code once the S3 bug is fixed
        # object.upload_stream(@options) do |s3|
        #   s3.binmode
        #   streams.reader(io, &block)
        # end
      end

      def each(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        existing_files = s3_bucket.objects(prefix: root).collect(&:key)

        flags = 0
        flags |= File::FNM_CASEFOLD unless case_sensitive
        flags |= File::FNM_DOTMATCH unless hidden

        Pathname.glob(pattern, flags) do |full_path|
          next if !directories && full_path.directory?

          yield(self.class.new(full_path.to_s))
        end
        # File.fnmatch(pattern, path, File::FNM_EXTGLOB)
        # Dir.glob
      end

      private

      # Sample URI: s3://mybucket/user/abc.zip
      def parse_uri(uri)
        uri = URI.parse(uri)
        raise "Invalid URI. Required Format: 's3://<bucket_name>/<key>'" unless uri.scheme == 's3'

        @bucket = uri.host
        @key    = uri.path.sub(%r{\A/}, '')
      end
    end
  end
end
