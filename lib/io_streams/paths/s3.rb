require "uri"

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      attr_reader :bucket_name, :key, :client

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
      # Writer specific options:
      #
      # @option params [String] :acl
      #   The canned ACL to apply to the object.
      #
      # @option params [String] :cache_control
      #   Specifies caching behavior along the request/reply chain.
      #
      # @option params [String] :content_disposition
      #   Specifies presentational information for the object.
      #
      # @option params [String] :content_encoding
      #   Specifies what content encodings have been applied to the object and
      #   thus what decoding mechanisms must be applied to obtain the media-type
      #   referenced by the Content-Type header field.
      #
      # @option params [String] :content_language
      #   The language the content is in.
      #
      # @option params [Integer] :content_length
      #   Size of the body in bytes. This parameter is useful when the size of
      #   the body cannot be determined automatically.
      #
      # @option params [String] :content_md5
      #   The base64-encoded 128-bit MD5 digest of the part data. This parameter
      #   is auto-populated when using the command from the CLI. This parameted
      #   is required if object lock parameters are specified.
      #
      # @option params [String] :content_type
      #   A standard MIME type describing the format of the object data.
      #
      # @option params [Time,DateTime,Date,Integer,String] :expires
      #   The date and time at which the object is no longer cacheable.
      #
      # @option params [String] :grant_full_control
      #   Gives the grantee READ, READ\_ACP, and WRITE\_ACP permissions on the
      #   object.
      #
      # @option params [String] :grant_read
      #   Allows grantee to read the object data and its metadata.
      #
      # @option params [String] :grant_read_acp
      #   Allows grantee to read the object ACL.
      #
      # @option params [String] :grant_write_acp
      #   Allows grantee to write the ACL for the applicable object.
      #
      # @option params [required, String] :key
      #   Object key for which the PUT operation was initiated.
      #
      # @option params [Hash<String,String>] :metadata
      #   A map of metadata to store with the object in S3.
      #
      # @option params [String] :server_side_encryption
      #   The Server-side encryption algorithm used when storing this object in
      #   S3 (e.g., AES256, aws:kms).
      #
      # @option params [String] :storage_class
      #   The type of storage to use for the object. Defaults to 'STANDARD'.
      #
      # @option params [String] :website_redirect_location
      #   If the bucket is configured as a website, redirects requests for this
      #   object to another object in the same bucket or to an external URL.
      #   Amazon S3 stores the value of this header in the object metadata.
      #
      # @option params [String] :sse_customer_algorithm
      #   Specifies the algorithm to use to when encrypting the object (e.g.,
      #   AES256).
      #
      # @option params [String] :sse_customer_key
      #   Specifies the customer-provided encryption key for Amazon S3 to use in
      #   encrypting data. This value is used to store the object and then it is
      #   discarded; Amazon does not store the encryption key. The key must be
      #   appropriate for use with the algorithm specified in the
      #   x-amz-server-side​-encryption​-customer-algorithm header.
      #
      # @option params [String] :sse_customer_key_md5
      #   Specifies the 128-bit MD5 digest of the encryption key according to
      #   RFC 1321. Amazon S3 uses this header for a message integrity check to
      #   ensure the encryption key was transmitted without error.
      #
      # @option params [String] :ssekms_key_id
      #   Specifies the AWS KMS key ID to use for object encryption. All GET and
      #   PUT requests for an object protected by AWS KMS will fail if not made
      #   via SSL or using SigV4. Documentation on configuring any of the
      #   officially supported AWS SDKs and CLI can be found at
      #   http://docs.aws.amazon.com/AmazonS3/latest/dev/UsingAWSSDK.html#specify-signature-version
      #
      # @option params [String] :ssekms_encryption_context
      #   Specifies the AWS KMS Encryption Context to use for object encryption.
      #   The value of this header is a base64-encoded UTF-8 string holding JSON
      #   with the encryption context key-value pairs.
      #
      # @option params [String] :request_payer
      #   Confirms that the requester knows that she or he will be charged for
      #   the request. Bucket owners need not specify this parameter in their
      #   requests. Documentation on downloading objects from requester pays
      #   buckets can be found at
      #   http://docs.aws.amazon.com/AmazonS3/latest/dev/ObjectsinRequesterPaysBuckets.html
      #
      # @option params [String] :tagging
      #   The tag-set for the object. The tag-set must be encoded as URL Query
      #   parameters. (For example, "Key1=Value1")
      #
      # @option params [String] :object_lock_mode
      #   The object lock mode that you want to apply to this object.
      #
      # @option params [Time,DateTime,Date,Integer,String] :object_lock_retain_until_date
      #   The date and time when you want this object's object lock to expire.
      #
      # @option params [String] :object_lock_legal_hold_status
      #   The Legal Hold status that you want to apply to the specified object.
      def initialize(url, client: Aws::S3::Client.new, **args)
        Utils.load_dependency('aws-sdk-s3', 'AWS S3') unless defined?(::Aws::S3::Resource)

        uri = URI.parse(url)
        raise "Invalid URI. Required Format: 's3://<bucket_name>/<key>'" unless uri.scheme == 's3'

        @bucket_name = uri.host
        @key         = uri.path.sub(%r{\A/}, '')
        @client      = client
        @options     = args
        super(url)
      end

      def delete
        # TODO: Handle when file does not exist
        client.delete_object(bucket: bucket_name, key: key)
        self
      end

      def exist?
        resp = client.head_object(bucket: bucket_name, key: key)
      end

      # S3 logically creates paths when a key is set.
      def mkpath
        self
      end

      def mkdir
        self
      end

      def size
        resp = client.head_object(bucket: bucket_name, key: key)
        resp.content_length
      end

      # TODO: delete_all

      # Read from AWS S3 file.
      def reader(&block)
        # Since S3 download only supports a push stream, write it to a tempfile first.
        Utils.temp_file_name("iostreams_s3") do |file_name|
          read_file(file_name)

          # Return a read stream to the temp file
          ::File.new(file_name, 'rb', &block)
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def read_file(file_name)
        client.get_object(@options.merge(response_target: file_name, bucket: bucket_name, key: key))
      end

      # Write to AWS S3
      #
      # Raises [MultipartUploadError] If an object is being uploaded in
      #   parts, and the upload can not be completed, then the upload is
      #   aborted and this error is raised.  The raised error has a `#errors`
      #   method that returns the failures that caused the upload to be
      #   aborted.
      def writer(&block)
        # Since S3 upload only supports a pull stream, write it to a tempfile first.
        Utils.temp_file_name("iostreams_s3") do |file_name|
          ::File.open(file_name, "wb", &block)

          # Upload file once all data has been written to it
          write_file(file_name)
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def write_file(file_name)
        client.put_object(@options.merge(bucket: bucket_name, key: key, body: file_name))
      end

      # Notes:
      # - With S3 all lookups are recursive regardless of whether the pattern includes `**`.
      #   This is because the object list call only takes a key prefix.
      def each_child(pattern = "**/*", case_sensitive: false, directories: false, hidden: false)
        raise(NotImplementedError, "AWS S3 #each_child does not yet return directories") if directories

        matcher = Matcher.new(self, pattern, case_sensitive: case_sensitive, hidden: hidden)
        prefix  = matcher.path.to_s
        marker  = nil
        loop do
          # Fetches upto 1,000 entries at a time
          resp = client.list_objects(bucket: bucket_name, prefix: prefix, delimiter: "/", marker: marker)
          resp.contents.each do |object|
            file_name = object.key
            next unless matcher.match?(file_name)

            yield self.class.new(file_name)
          end
          marker = resp.next_marker
          break if marker.nil?
        end
      end
    end
  end
end
