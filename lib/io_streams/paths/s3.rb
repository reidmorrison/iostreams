# frozen_string_literal: true

require "uri"

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      attr_reader :bucket_name, :options

      # Largest file size supported by the S3 copy object api.
      S3_COPY_OBJECT_SIZE_LIMIT = 5 * 1024 * 1024 * 1024

      # When an upload file exceeds this size, it is uploaded with the SDK's file upload, see `Sdk.upload_file`, which
      # only uses a multipart upload once the file reaches the SDK's `multipart_threshold`, 100MB by default, and
      # otherwise a single `put_object` request, like a smaller file.
      MULTIPART_UPLOAD_SIZE = 5 * 1024 * 1024

      autoload :ClientCache, "io_streams/paths/s3/client_cache"
      autoload :Directories, "io_streams/paths/s3/directories"
      autoload :Failure, "io_streams/paths/s3/failure"
      autoload :Listing, "io_streams/paths/s3/listing"
      autoload :RangeReader, "io_streams/paths/s3/range_reader"
      autoload :Sdk, "io_streams/paths/s3/sdk"
      autoload :Uploader, "io_streams/paths/s3/uploader"

      # The secret access key, also within `client:`, and the customer encryption keys, see
      # IOStreams::Path.redact_options. A session token and credentials are always sensitive by name.
      def self.sensitive_option_names = %i[secret_access_key sse_customer_key copy_source_sse_customer_key]

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
      # writing or copying to this path, and `request_payer` to every request. An option that no request
      # accepts raises ArgumentError.
      #
      # A direct copy within S3, with `convert: false` or `#move_to`, is made with the client and options of
      # the target, which it writes, and the customer encryption key and `request_payer` of the source.
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
        uri = Utils::URI.new(url)
        raise "Invalid URI. Required Format: 's3://<bucket_name>/<key>'" unless uri.scheme == "s3"

        validate_url!(uri, url)
        @bucket_name = uri.hostname
        key          = utf8_key(uri.path.delete_prefix("/"))

        # The client is created when first used, and is shared by copies of this path, such as from `#join`.
        @client_cache = ClientCache.new(client, access_key_id: access_key_id, secret_access_key: secret_access_key,
                                                region: region)

        # A copy of each option, so that a Hash supplied as an option, such as `metadata:`, is not shared, see #options.
        @options = deep_copy(args)
        @options.merge!(uri.query.transform_keys(&:to_sym)) if uri.query
        Sdk.check_options(options.keys)

        super(key)
      end

      # Freezes the options too, see #options and `IOStreams::Path#freeze`.
      def freeze
        deep_freeze(@options)
        super
      end

      # Returns [String] the url of this path, with each `%`, `?` and `#` in the key percent-encoded, so that the
      # path can be created again from its url, see `IOStreams::Utils::URI.encode_path`. The key is as it is, so that
      # a key that starts with `/`, which S3 can hold, is `s3://bucket//a.csv`, rather than the key `a.csv`.
      def to_s
        "s3://#{bucket_name}/#{Utils::URI.encode_path(path)}"
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative? = false

      def absolute? = true

      def delete
        Sdk.load
        authorize!
        unless_not_found(nil) { request(:delete_object, bucket: bucket_name, key: path) }
        self
      end

      # Deletes this object, and every key within this path as a directory, such as `a/b.csv` and `a/c/d.csv`
      # for the path `s3://bucket/a`. S3 has no directories, so these are all the keys that it holds within it.
      #
      # Returns self
      #
      # Notes:
      # * No error is raised when there is nothing to delete.
      # * A key that only starts with the same characters, such as `a.csv` for `s3://bucket/a`, is not deleted.
      def delete_all
        authorize!
        delete if file_key?
        listing.each_page(directory_prefix) { |page| delete_keys(page.contents.map { |object| {key: object.key} }) }
        self
      end

      # Returns [true|false] whether this path is an object, see #file?, or a directory, see #directory?, like a local
      # path. When no object has the key, a second request looks for a key within it.
      def exist?
        Sdk.load
        authorize!
        object_exists? || directory_exists?
      end

      # Returns [true|false] whether an object exists with this key.
      # A folder object, with a key ending in `/`, is a directory rather than a file.
      def file?
        Sdk.load
        authorize!
        object_exists?
      end

      # Returns [true|false] whether this path is a directory, which S3 only has within keys: when any key
      # starts with this path followed by `/`, such as `a` and `a/b` for the key `a/b/c.csv`, or when a folder
      # object exists, such as `a/`. The bucket itself is a directory when it exists.
      def directory?
        Sdk.load
        authorize!
        directory_exists?
      end

      # Returns [true|false] whether this path is an object without any data, or a directory without any keys
      # within it other than its folder object.
      def empty?
        authorize!
        if file_key?
          size = object_size
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
        reject_move_onto_itself!(target)
        copy_to(target, convert: false)
        delete
        target
      end

      # Make S3 perform direct copies within S3 itself, also for `#copy_to` another S3 path, which asks it.
      #
      # The copy writes this object, so it is requested with the client and options of this path, such as its `acl`,
      # and the source supplies what S3 needs to read it, such as its customer encryption key, see
      # `#copy_source_parameters`.
      #
      # Returns [Integer] the number of bytes copied, like any other copy.
      def copy_from(source_path, convert: true, **args)
        return super(source_path, convert: true, **args) if convert

        source = to_stream(source_path)
        return super(source, convert: convert, **args) unless source.is_a?(self.class)

        bytes = source.object_size.to_i
        return super(source, convert: convert, **args) if bytes >= S3_COPY_OBJECT_SIZE_LIMIT

        reject_copy_options!(UNCONVERTED_COPY, **args)
        authorize!
        source.authorize!
        copy_object_from(source)
        bytes
      end

      # S3 logically creates paths when a key is set.
      def mkpath = self

      def mkdir = self

      def size
        head_object.content_length
      end

      def mtime
        head_object.last_modified
      end

      # Read from AWS S3 file.
      #
      # Reads the object one range at a time, as the block reads it, see `RangeReader`. Unless the `range` or
      # `part_number` option chooses the bytes to read, which are downloaded into a temp file first.
      def stream_reader(&block)
        if RangeReader.supports?(options_for(:get_object).keys)
          authorize!
          input = RangeReader.new(->(**params) { request(:get_object, bucket: bucket_name, key: path, **params) })
          return builder.reader(input, &block)
        end

        # Since a single S3 download only supports a push stream, write it to a tempfile first.
        Utils.private_temp_file("iostreams_s3", purpose: "the download of #{display_name}") do |file_name|
          read_file(file_name)

          ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def read_file(file_name)
        authorize!
        ::File.open(file_name, "wb") do |file|
          request(:get_object, response_target: file, bucket: bucket_name, key: path)
        end
      end

      # Write to AWS S3
      #
      # Uploads the data as it is written, see `Uploader`. Unless an option describes the whole object, such as
      # `content_md5`, when the data is written into a temp file, which is uploaded once the block completes.
      #
      # Raises [MultipartUploadError] when the temp file is uploaded in parts, and the upload can not be completed,
      #   then the upload is aborted and this error is raised. The raised error has a `#errors` method that returns the
      #   failures that caused the upload to be aborted.
      def stream_writer(&block)
        # Raises LoadError without the AWS SDK before the block writes any data, rather than once it has all been written.
        Sdk.load
        if Uploader.supports?(options_for(:put_object).keys)
          authorize!
          request = ->(operation, **params) { request(operation, bucket: bucket_name, key: path, **params) }
          return Uploader.upload(request) { |io| builder.writer(io, &block) }
        end

        # Since S3 upload only supports a pull stream, write it to a tempfile first.
        # Uploads the file only once all data has been written to it, including when the block leaves early, such as
        # with `break`, as a local file keeps what was written, see `IOStreams::Utils.finish_or_abort`.
        Utils.private_temp_file("iostreams_s3", purpose: "the upload to #{display_name}") do |file_name|
          Utils.finish_or_abort(finish: -> { write_file(file_name) }) do
            ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }
          end
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def write_file(file_name)
        authorize!
        if ::File.size(file_name) > MULTIPART_UPLOAD_SIZE
          # A multipart upload once the file reaches the SDK's multipart threshold, see `MULTIPART_UPLOAD_SIZE`.
          # Supplies each part of a multipart upload with the options that it accepts.
          tag_failure { Sdk.upload_file(client, file_name, bucket: bucket_name, key: path, **options_for(:put_object)) }
        else
          ::File.open(file_name, "rb") do |file|
            request(:put_object, bucket: bucket_name, key: path, body: file)
          end
        end
      end

      # Yields each child that matches the pattern, and its attributes, the hash of the object listed by S3.
      #
      # S3 has no directories, only keys that contain `/`. With `directories: true` the directories within the
      # keys are also returned, such as `a` and `a/b` for the key `a/b/c.csv`, along with any empty folder
      # created with a key ending in `/`. The attributes of a directory are empty, unless it is such a folder,
      # see `Listing#each`.
      #
      # Notes:
      # - S3 lists every key below the directory, unless the pattern cannot match a name below it, such as `*.csv`,
      #   when it only lists the keys directly within it, see `Listing#each`.
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false, &)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        authorize!
        matcher = Matcher.new(pattern, case_sensitive: case_sensitive, hidden: hidden)
        # Use the key directly rather than parsing it as part of a URL.
        prefix  = key_within(path, matcher.directory)

        # When the pattern is an exact file name without any pattern characters
        if matcher.exact?
          Sdk.load
          child = child_path(key_within(prefix, matcher.pattern))
          return unless allowed_child?(child)

          attributes = child.exact_attributes(directories)
          yield(child, attributes) if attributes
          # Otherwise the name is matched within its directory, ignoring case, like a local path.
          return if attributes || matcher.case_sensitive?
        end

        # List within the key as a directory, so that a key such as "reports" does not also list "reports_2024.csv".
        prefix = "#{prefix}/" unless prefix.empty? || prefix.end_with?("/")
        listing.each(prefix, matcher, directories: directories) do |key, attributes|
          child = child_path(key)
          yield(child, attributes) if allowed_child?(child)
        end
        nil
      end

      # On S3 only files that are completely saved are visible.
      def partial_files_visible? = false

      # Returns [Aws::S3::Client] the client, created when first used since resolving the credentials can be slow,
      # for example from the EC2 instance metadata service.
      def client
        Sdk.load
        @client_cache.client
      end

      protected

      # A copy has its own options, so that changing them does not change this path, see #options.
      def initialize_copy(source)
        super
        @options = deep_copy(@options)
      end

      # Sets the key, for example when called by `#join` or `#directory`.
      #
      # The directory of a key without a directory, such as `a.csv`, is the bucket itself, not the key `.`.
      def path=(path)
        super(path == "." ? "" : utf8_key(path))
      end

      # Returns [Hash] the options that the S3 operation accepts.
      #
      # Options apply to the operations that accept them, so for example `acl` applies when writing
      # and copying, and `request_payer` to every operation.
      def options_for(operation)
        options.slice(*Sdk.operation_options(operation))
      end

      # Returns [String] the key of the name joined to this path, see `IOStreams::Path#join`. A name joined to the
      # bucket itself is a key within it, as a name joined to the local directory `/` is within it, so that a name that
      # starts with `/`, such as from untrusted input, is not a key that starts with `/`, outside a directory such as
      # `exports/` that it names.
      def joined_path(name)
        return super unless path.empty?

        name = name.delete_prefix("/") while name.start_with?("/")
        name
      end

      # Returns [String] the key with `.`, `..` and repeated `/` removed, see `IOStreams::Path#clean_name`, keeping a
      # trailing `/`, since a key that ends with it, such as that of a folder object, is another object.
      def clean_name(name)
        clean = super
        name.end_with?("/") && !clean.end_with?("/") ? "#{clean}/" : clean
      end

      # Returns [Integer] the size of the object, or nil when it does not exist, see `#empty?`. A direct copy of an object
      # that does not exist then raises `NoSuchKey` from S3, as it did before `#size` raised for it.
      def object_size
        size
      rescue Errors::NotFound
        nil
      end

      # Returns [Hash] the attributes of this object, see `#object_attributes`, empty attributes when it is a directory
      # and `directories`, or nil when it is neither, for `#each_child` to yield this path as an exact name.
      #
      # Only the requests are rescued, rather than the block of `#each_child`, so that an exception that the block
      # raises, such as `Aws::S3::Errors::NotFound` for another path, is raised as it is.
      def exact_attributes(directories)
        object_attributes || ({} if directories && directory?)
      end

      # Returns [Hash] the attributes of this object, in the same form as those of a listed object, see `#each_child`,
      # or nil when it does not exist. Load the AWS SDK first, see `Sdk.load`.
      def object_attributes
        response = unless_not_found(nil) { request(:head_object, bucket: bucket_name, key: path) }
        return unless response

        {key: path, last_modified: response.last_modified, etag: response.etag, size: response.content_length,
         storage_class: response.storage_class}.compact
      end

      # Paths in the same bucket are in the same store, see `IOStreams::Path#same_store?`.
      def store = bucket_name

      # Copies the source object into this object within S3, see `#copy_from`. A missing object is a failure of the
      # source, and any other failure is one of this path, since the size of the source is read before the copy, which
      # raises when the source cannot be read.
      def copy_object_from(source)
        Sdk.load
        tag_failure do
          client.copy_object(options_for(:copy_object).merge(source.copy_source_parameters, bucket: bucket_name, key: path))
        rescue Aws::S3::Errors::NoSuchKey => e
          raise(Errors::NotFound.tag(e, source.display_name))
        end
      end

      # Returns [Hash] the parameters of a copy that name this object as its source, which S3 requires to be url-encoded,
      # with the options of this path that S3 needs to read it, see `Sdk.copy_source_options`.
      def copy_source_parameters
        {copy_source: "#{bucket_name}/#{Seahorse::Util.uri_path_escape(path)}", **Sdk.copy_source_options(options)}
      end

      private

      # Returns [Module] the kind of failure that an exception raised by S3 means, see `Failure.kind`.
      def failure_kind(exception)
        Failure.kind(exception)
      end

      # Makes the S3 request, with the options that the operation accepts, tagging a failure with the kind of
      # failure that it means, see `#failure_kind`.
      def request(operation, **params)
        tag_failure { client.public_send(operation, options_for(operation).merge(params)) }
      end

      # Deletes upto 1,000 keys in one request, raising when S3 could not delete any of them.
      def delete_keys(keys)
        errors = keys.empty? ? [] : request(:delete_objects, bucket: bucket_name, delete: {objects: keys, quiet: true}).errors
        return if errors.empty?

        raise(Errors::CommunicationsFailure,
              "Failed to delete #{errors.size} keys from #{display_name}, such as #{errors.first.key}: #{errors.first.message}")
      end

      # Returns the response of a HEAD request for this object.
      #
      # Raises [Errno::EISDIR] tagged as `IOStreams::Errors::NotFound` for the bucket, which is not an object, since
      # S3 cannot be asked for an object without a key.
      def head_object
        authorize!
        if path.empty?
          raise(Errors::NotFound.tag(Errno::EISDIR.new("#{display_name} is the bucket, which is not an object"), display_name))
        end

        request(:head_object, bucket: bucket_name, key: path)
      end

      # Returns [true|false] whether an object, other than a folder object, has this key.
      # Load the AWS SDK first, see `Sdk.load`.
      def object_exists?
        file_key? && unless_not_found(false) { request(:head_object, bucket: bucket_name, key: path) && true }
      end

      # Returns [true|false] whether this path is a directory, see #directory?. Load the AWS SDK first, see `Sdk.load`.
      def directory_exists?
        return directory_keys(1).any? unless path.empty?

        request(:list_objects_v2, bucket: bucket_name, max_keys: 1) && true
      rescue Aws::S3::Errors::NoSuchBucket
        false
      end

      # Returns [true|false] whether this path can be the key of a file, rather than the bucket or a folder object.
      def file_key?
        !path.empty? && !path.end_with?("/")
      end

      # Returns [String] the prefix of the keys within this path as a directory.
      def directory_prefix
        path.empty? ? "" : "#{path.chomp('/')}/"
      end

      # Returns the result of the block, or the supplied value when the object does not exist.
      # Load the AWS SDK first, see `Sdk.load`.
      def unless_not_found(value)
        yield
      rescue Aws::S3::Errors::NotFound
        value
      end

      # Returns [Array<String>] upto `max_keys` of the keys within this path as a directory.
      def directory_keys(max_keys)
        request(:list_objects_v2, bucket: bucket_name, prefix: directory_prefix, max_keys: max_keys).contents.map(&:key)
      end

      # Returns [String] the key.
      #
      # Raises ArgumentError for a key that is not valid UTF-8, such as a name written in Latin-1, since every S3 key
      # is UTF-8, rather than the error of the AWS SDK when it is first used.
      def utf8_key(key)
        return key if key.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        raise(ArgumentError, "An S3 key must be valid UTF-8: s3://#{bucket_name}/#{Utils.display_text(key)}")
      end

      # Raises ArgumentError for a part of the url that S3 does not use, rather than ignore it.
      def validate_url!(uri, url)
        problem =
          if uri.hostname.to_s.empty?
            "it must name a bucket, such as 's3://bucket/a.csv'"
          elsif uri.fragment
            "percent-encode a '#' in a key as '%23', since it starts a fragment, which an S3 url cannot have"
          elsif uri.port
            "it cannot have a port. Supply the endpoint of another service that implements the S3 API with " \
              "client: {endpoint: \"https://host:port\"}"
          elsif uri.user || uri.password
            "it cannot have a user name or password. Supply the credentials with access_key_id: and secret_access_key:"
          end
        raise(Utils::URI.invalid("S3", url, problem)) if problem
      end

      # Returns [Listing] the listing of the objects in the bucket, which makes each request of this path.
      def listing
        Listing.new(->(**params) { request(:list_objects_v2, bucket: bucket_name, **params) })
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

      # Returns [String] the key of the supplied name within the supplied key, or the key itself for an empty name.
      def key_within(key, name)
        return key if name.empty?

        key.empty? ? name : ::File.join(key, name)
      end

      # Set the key directly rather than parsing it as part of a URL, since a key can contain
      # characters such as `?`, `+` or `%` that a URL parser would treat as a query or as escapes.
      #
      # The child uses this path's client and options, so that it has the same credentials, region
      # and request parameters, such as `request_payer` or an SSE-C key.
      def child_path(key)
        child      = self.class.new("s3://#{bucket_name}", client: client, **options)
        child.path = key.dup.freeze
        child
      end
    end
  end
end
