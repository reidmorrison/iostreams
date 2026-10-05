require "uri"

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      attr_reader :bucket_name, :options

      # Largest file size supported by the S3 copy object api.
      S3_COPY_OBJECT_SIZE_LIMIT = 5 * 1024 * 1024 * 1024

      # The S3 operations that a path calls, each of which is supplied the options that it accepts.
      OPERATIONS = %i[get_object head_object put_object copy_object delete_object list_objects_v2].freeze
      # Request parameters that the path sets itself, which cannot be supplied as options.
      PATH_PARAMETERS = %i[bucket key body response_target copy_source prefix continuation_token].freeze

      # When an upload file exceeds this size, use a multipart file upload.
      MULTIPART_UPLOAD_SIZE = 5 * 1024 * 1024

      # Arguments:
      #
      # url: [String]
      #   Prefix must be: `s3://`
      #   followed by bucket name,
      #   followed by key.
      #   Examples:
      #     s3://my-bucket-name/file_name.txt
      #     s3://my-bucket-name/some_path/file_name.csv
      #
      #   Any query string in the url is added to the S3 request parameters, for example:
      #     s3://my-bucket-name/file_name.csv?acl=bucket-owner-full-control
      #
      #   SECURITY WARNING:
      #     Do not interpolate untrusted file names into the url, since a name such as
      #     `file.csv?acl=public-read` would set request parameters.
      #     Instead join untrusted names onto the path, which does not parse them as a query:
      #       IOStreams.path("s3://my-bucket-name/uploads").join(untrusted_name)
      #
      # access_key_id: [String]
      #   AWS Access Key Id to use to access this bucket.
      #
      # secret_access_key: [String]
      #   AWS Secret Access Key Id to use to access this bucket.
      #
      # region: [String]
      #   The AWS region to connect to.
      #   Defaults to region set in environment variable, or credential files.
      #
      # client: [Aws::S3::Client | Hash]
      #   Supply the AWS S3 Client instance to use for this path.
      #   Or, when a Hash, build a new client using the hash parameters.
      #
      #   Example:
      #     client = Aws::S3::Client.new(endpoint: "https://s3.test.com")
      #     IOStreams::Paths::S3.new("s3://bucket/path/file_name.txt", client: client)
      #
      #   Example:
      #     IOStreams::Paths::S3.new("s3://bucket/path/file_name.txt", client: { endpoint: "https://s3.test.com" })
      #
      # Any other options are supplied to each S3 request that accepts them, for example `acl` when
      # writing or copying, and `request_payer` to every request. An option that no request accepts
      # raises ArgumentError.
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
      #   x-amz-server-side-encryption-customer-algorithm header.
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
      def initialize(url, client: nil, access_key_id: nil, secret_access_key: nil, region: nil, **args)
        Utils.load_soft_dependency("aws-sdk-s3", "AWS S3") unless defined?(::Aws::S3::Client)

        uri = Utils::URI.new(url)
        raise "Invalid URI. Required Format: 's3://<bucket_name>/<key>'" unless uri.scheme == "s3"

        @bucket_name = uri.hostname
        key          = uri.path.sub(%r{\A/}, "")

        # The client is created when first used, and is shared by copies of this path, such as from `#join`.
        # It is held in a Hash so that it is also created when this path is frozen, for example a root path.
        @client_cache = {}
        if client && !client.is_a?(Hash)
          @client_cache[:client] = client
        else
          @client_options                     = client.is_a?(Hash) ? client.dup : {}
          @client_options[:access_key_id]     = access_key_id if access_key_id
          @client_options[:secret_access_key] = secret_access_key if secret_access_key
          @client_options[:region]            = region if region
        end

        @options = args
        @options.merge!(uri.query.transform_keys(&:to_sym)) if uri.query
        validate_options!

        super(key)
      end

      # Returns [Array<Symbol>] the options that the S3 operation accepts.
      def self.operation_options(operation)
        @operation_options ||= {}
        @operation_options[operation] ||=
          (::Aws::S3::Client.api.operation(operation).input.shape.member_names - PATH_PARAMETERS).freeze
      end

      def to_s
        ::File.join("s3://", bucket_name, path)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def absolute?
        true
      end

      def delete
        authorize!
        client.delete_object(options_for(:delete_object).merge(bucket: bucket_name, key: path))
        self
      rescue Aws::S3::Errors::NotFound
        self
      end

      def exist?
        authorize!
        client.head_object(options_for(:head_object).merge(bucket: bucket_name, key: path))
        true
      rescue Aws::S3::Errors::NotFound
        false
      end

      # Returns [true|false] whether an object exists with this key.
      # A folder object, with a key ending in `/`, is a directory rather than a file.
      def file?
        authorize!
        file_key? && exist?
      end

      # Returns [true|false] whether this path is a directory, which S3 only has within keys: when any key
      # starts with this path followed by `/`, such as `a` and `a/b` for the key `a/b/c.csv`, or when a folder
      # object exists, such as `a/`. The bucket itself is always a directory.
      def directory?
        authorize!
        path.empty? || directory_keys(1).any?
      end

      # Returns [true|false] whether this path is an object without any data, or a directory without any keys
      # within it other than its folder object.
      def empty?
        authorize!
        if file_key?
          size = self.size
          return size.zero? if size
        end

        keys = directory_keys(2)
        path.empty? ? keys.empty? : keys == [directory_prefix]
      end

      # Moves this file to the `target_path` by copying it to the new name and then deleting the current file.
      #
      # Notes:
      # - Can copy across buckets.
      # - No stream conversions are applied.
      def move_to(target_path)
        target = to_stream(target_path)
        copy_to(target, convert: false)
        delete
        target
      end

      # Make S3 perform direct copies within S3 itself.
      #
      # Returns [Integer] the number of bytes copied, like any other copy.
      def copy_to(target_path, convert: true, **args)
        return super if convert

        bytes = size.to_i
        return super if bytes >= S3_COPY_OBJECT_SIZE_LIMIT

        target = to_stream(target_path)
        return super(target, convert: convert, **args) unless target.is_a?(self.class)

        reject_copy_options!(UNCONVERTED_COPY, **args)
        authorize!
        target.authorize!
        client.copy_object(
          options_for(:copy_object).merge(bucket: target.bucket_name, key: target.path, copy_source: copy_source)
        )
        bytes
      end

      # Make S3 perform direct copies within S3 itself.
      #
      # Returns [Integer] the number of bytes copied, like any other copy.
      def copy_from(source_path, convert: true, **args)
        return super(source_path, convert: true, **args) if convert

        source = to_stream(source_path)
        return super(source, convert: convert, **args) unless source.is_a?(self.class)

        bytes = source.size.to_i
        return super(source, convert: convert, **args) if bytes >= S3_COPY_OBJECT_SIZE_LIMIT

        reject_copy_options!(UNCONVERTED_COPY, **args)
        authorize!
        source.authorize!
        client.copy_object(options_for(:copy_object).merge(bucket: bucket_name, key: path, copy_source: source.copy_source))
        bytes
      end

      # S3 logically creates paths when a key is set.
      def mkpath
        self
      end

      def mkdir
        self
      end

      def size
        authorize!
        client.head_object(options_for(:head_object).merge(bucket: bucket_name, key: path)).content_length
      rescue Aws::S3::Errors::NotFound
        nil
      end

      # TODO: delete_all

      # Read from AWS S3 file.
      def stream_reader(&block)
        # Since S3 download only supports a push stream, write it to a tempfile first.
        Utils.private_temp_file("iostreams_s3") do |file_name|
          read_file(file_name)

          ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def read_file(file_name)
        authorize!
        ::File.open(file_name, "wb") do |file|
          client.get_object(options_for(:get_object).merge(response_target: file, bucket: bucket_name, key: path))
        end
      end

      # Write to AWS S3
      #
      # Raises [MultipartUploadError] If an object is being uploaded in
      #   parts, and the upload can not be completed, then the upload is
      #   aborted and this error is raised.  The raised error has a `#errors`
      #   method that returns the failures that caused the upload to be
      #   aborted.
      def stream_writer(&block)
        # Since S3 upload only supports a pull stream, write it to a tempfile first.
        Utils.private_temp_file("iostreams_s3") do |file_name|
          result = ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }

          # Upload file only once all data has been written to it
          write_file(file_name)
          result
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def write_file(file_name)
        authorize!
        if ::File.size(file_name) > MULTIPART_UPLOAD_SIZE
          # Use multipart file upload
          s3  = Aws::S3::Resource.new(client: client)
          obj = s3.bucket(bucket_name).object(path)
          # Supplies each part of a multipart upload with the options that it accepts.
          obj.upload_file(file_name, options_for(:put_object))
        else
          ::File.open(file_name, "rb") do |file|
            client.put_object(options_for(:put_object).merge(bucket: bucket_name, key: path, body: file))
          end
        end
      end

      # Yields each child that matches the pattern, and its attributes, the hash of the object listed by S3.
      #
      # S3 has no directories, only keys that contain `/`. With `directories: true` the directories within the
      # keys are also returned, such as `a` and `a/b` for the key `a/b/c.csv`, along with any empty folder
      # created with a key ending in `/`. The attributes of a directory are empty, unless it is such a folder.
      #
      # Notes:
      # - Currently all S3 lookups are recursive as of the pattern regardless of whether the pattern includes `**`.
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false, &)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        authorize!
        matcher = Matcher.new(self, pattern, case_sensitive: case_sensitive, hidden: hidden)

        # When the pattern includes an exact file name without any pattern characters
        if matcher.pattern.nil?
          each_exact_child(matcher.path, directories, &)
          return
        end

        # Use the key directly rather than parsing it as part of a URL, and list within it as a directory,
        # so that a key such as "reports" does not also list "reports_2024.csv".
        prefix = matcher.path.path
        prefix = "#{prefix}/" unless prefix.empty? || prefix.end_with?("/")
        listed = {}
        each_object(prefix) do |name, object|
          relative = object.key.delete_prefix(prefix)
          if directories
            each_directory(relative, listed) do |directory|
              next unless ::File.fnmatch?(matcher.pattern, directory, matcher.flags)

              child = child_path(name, "#{prefix}#{directory}")
              yield(child, relative == "#{directory}/" ? object.to_h : {}) if allowed_child?(child)
            end
          end
          next if object.key.end_with?("/")
          next unless ::File.fnmatch?(matcher.pattern, relative, matcher.flags)

          child = child_path(name, object.key)
          next unless allowed_child?(child)

          yield(child, object.to_h)
        end
        nil
      end

      # On S3 only files that are completely saved are visible.
      def partial_files_visible?
        false
      end

      # Returns [Aws::S3::Client] the client, created when first used since resolving the credentials can be slow,
      # for example from the EC2 instance metadata service.
      def client
        @client_cache[:client] ||= ::Aws::S3::Client.new(@client_options)
      end

      protected

      # Sets the key, for example when called by `#join` or `#directory`.
      #
      # The directory of a key without a directory, such as `a.csv`, is the bucket itself, not the key `.`.
      def path=(path)
        super(path == "." ? "" : path)
      end

      # Returns [Hash] the options that the S3 operation accepts.
      #
      # Options apply to the operations that accept them, so for example `acl` applies when writing
      # and copying, and `request_payer` to every operation.
      def options_for(operation)
        options.slice(*self.class.operation_options(operation))
      end

      # Returns [String] this object as the `copy_source` of a copy, which S3 requires to be url-encoded.
      def copy_source
        "#{bucket_name}/#{Seahorse::Util.uri_path_escape(path)}"
      end

      private

      # Returns [true|false] whether this path can be the key of a file, rather than the bucket or a folder object.
      def file_key?
        !path.empty? && !path.end_with?("/")
      end

      # Returns [String] the prefix of the keys within this path as a directory.
      def directory_prefix
        path.empty? ? "" : "#{path.chomp('/')}/"
      end

      # Returns [Array<String>] upto `max_keys` of the keys within this path as a directory.
      def directory_keys(max_keys)
        client.list_objects_v2(
          options_for(:list_objects_v2).merge(bucket: bucket_name, prefix: directory_prefix, max_keys: max_keys)
        ).contents.map(&:key)
      end

      # Skips the HEAD before a copy to this path, and the DELETE after a failed one.
      #
      # S3 only stores an object once its upload completes, and a multipart upload is aborted when it fails,
      # so a failed copy never leaves an incomplete object to delete. The DELETE could instead remove a
      # complete object when only the response to its upload was lost, or one created by another writer
      # during the copy.
      def existed_before_copy?
        true
      end

      # Options are strict: an option that no S3 operation accepts raises, so that a misspelled option is reported.
      def validate_options!
        accepted = OPERATIONS.flat_map { |operation| self.class.operation_options(operation) }
        unknown  = options.keys - accepted
        return if unknown.empty?

        raise(ArgumentError, "Unknown S3 #{unknown.size == 1 ? 'option' : 'options'}: #{unknown.map(&:inspect).join(', ')}")
      end

      # Yields the child, when it is an object, or a directory and `directories`, with its attributes,
      # in the same form as those of a listed object.
      def each_exact_child(child, directories)
        return unless allowed_child?(child)

        response = client.head_object(options_for(:head_object).merge(bucket: bucket_name, key: child.path))
        yield(child,
              {key:           child.path,
               last_modified: response.last_modified,
               etag:          response.etag,
               size:          response.content_length,
               storage_class: response.storage_class}.compact)
      rescue Aws::S3::Errors::NotFound
        return unless directories

        resp = client.list_objects_v2(
          options_for(:list_objects_v2).merge(bucket: bucket_name, prefix: "#{child.path}/", max_keys: 1)
        )
        yield(child, {}) if resp.contents.any?
      end

      # Yields the name of each directory within the relative key that has not already been listed,
      # such as `a` and `a/b` for `a/b/c.csv`, or for the empty folder `a/b/`.
      def each_directory(relative, listed)
        elements = relative.split("/")
        elements.pop unless relative.end_with?("/")
        elements.each_index do |index|
          break if elements[index].empty?

          directory = elements[0..index].join("/")
          next if listed.key?(directory)

          listed[directory] = true
          yield(directory)
        end
      end

      # Yields the bucket name and each object in the bucket whose key starts with the supplied prefix.
      def each_object(prefix)
        token = nil
        loop do
          # Fetches upto 1,000 entries at a time
          resp = client.list_objects_v2(
            options_for(:list_objects_v2).merge(bucket: bucket_name, prefix: prefix, continuation_token: token)
          )
          resp.contents.each { |object| yield(resp.name, object) }
          token = resp.next_continuation_token
          break if token.nil?
        end
      end

      # Returns [String] the bucket and key, which is compared against the allowed paths.
      #
      # S3 treats `.` and `..` in a key as ordinary characters, but other services that implement the
      # S3 API may resolve them, so keys containing them are denied.
      def allowed_location
        if path.split("/").intersect?([".", ".."])
          raise(Errors::AccessDenied, "Access denied to #{self}: '.' and '..' are not allowed in S3 keys")
        end

        to_s.sub(%r{/+\z}, "")
      end

      # Set the key directly rather than parsing it as part of a URL, since a key can contain
      # characters such as `?`, `+` or `%` that a URL parser would treat as a query or as escapes.
      #
      # The child uses this path's client and options, so that it has the same credentials, region
      # and request parameters, such as `request_payer` or an SSE-C key.
      def child_path(bucket_name, key)
        child      = self.class.new("s3://#{bucket_name}", client: client, **options)
        child.path = key.dup.freeze
        child
      end
    end
  end
end
