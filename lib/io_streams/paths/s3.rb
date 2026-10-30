require "uri"

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      attr_reader :bucket_name, :options

      # The secret access key, also within `client:`, and the customer encryption keys, see
      # IOStreams::Path.redact_options. A session token and credentials are always sensitive by name.
      def self.sensitive_option_names = %i[secret_access_key sse_customer_key copy_source_sse_customer_key]

      # Largest file size supported by the S3 copy object api.
      S3_COPY_OBJECT_SIZE_LIMIT = 5 * 1024 * 1024 * 1024

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

        if client && !client.is_a?(Hash)
          @client = client
        else
          @client_options                     = client.is_a?(Hash) ? client.dup : {}
          @client_options[:access_key_id]     = access_key_id if access_key_id
          @client_options[:secret_access_key] = secret_access_key if secret_access_key
          @client_options[:region]            = region if region
        end

        @options = uri.query ? args.merge(uri.query.transform_keys(&:to_sym)) : args

        super(key)
        # Each child that #each_child yields is a new path too, so nothing is checked while deprecation warnings are off.
        return unless Warning[:deprecated]

        warn_unusable_url(uri)
        warn_client_arguments(client, access_key_id: access_key_id, secret_access_key: secret_access_key, region: region)
        warn_unusable_options(args.keys) unless args.empty?
        warn_unusable_query(uri.query) if uri.query
      end

      # The S3 requests whose parameters IOStreams 3.0 takes as the options of a path, see .known_option_names.
      OPTION_OPERATIONS = %i[get_object head_object put_object copy_object delete_object delete_objects list_objects_v2].freeze
      private_constant :OPTION_OPERATIONS

      # The parameters of the S3 requests that a path sets itself, such as `key`, which it overrides, and those of a
      # listing that would change which keys it returns, or how, which IOStreams 3.0 does not take as the options of a
      # path, see .known_option_names.
      PATH_PARAMETERS = %i[
        bucket key body response_target copy_source prefix continuation_token delimiter delete encoding_type start_after
      ].freeze
      private_constant :PATH_PARAMETERS

      # Returns [Array<Symbol>] the options of a path that IOStreams 3.0 takes, which raises ArgumentError for any other
      # when the path is created: the parameters of its S3 requests, see OPTION_OPERATIONS, as the AWS SDK names them,
      # other than those that the path sets itself, see PATH_PARAMETERS. Load the AWS SDK first.
      def self.known_option_names
        @known_option_names ||=
          (OPTION_OPERATIONS.flat_map { |operation| ::Aws::S3::Client.api.operation(operation).input.shape.member_names }.uniq -
            PATH_PARAMETERS).freeze
      end

      def to_s
        Utils::PathName.join("s3://", bucket_name, path)
      end

      # Joining a name that starts with `/` to the bucket itself, see `IOStreams::Path#join`, gives the key that starts
      # with `/`, such as `/exports/a.csv`, while IOStreams v3.0 joins it as a key within the bucket, `exports/a.csv`, as
      # a name joined to the local directory `/` is within it. So it is deprecated, and reports a deprecation warning,
      # see `IOStreams::Deprecation`.
      def join(*elements)
        joined = super
        if path.empty? && joined.path.start_with?("/")
          Deprecation.warn("joining a name that starts with / to an S3 bucket is deprecated, since v3.0 joins it as " \
                           "a key within the bucket, such as exports/a.csv for /exports/a.csv: remove the leading /, " \
                           "or name a key that starts with / in the url, such as s3://bucket//exports/a.csv")
        end
        joined
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def delete
        authorize!
        client.delete_object(bucket: bucket_name, key: path)
        self
      rescue Aws::S3::Errors::NotFound
        self
      end

      def exist?
        authorize!
        client.head_object(bucket: bucket_name, key: path)
        true
      rescue Aws::S3::Errors::NotFound
        false
      end

      # Moves this file to the `target_path` by copying it to the new name and then deleting the current file.
      #
      # Notes:
      # - Can copy across buckets.
      # - No stream conversions are applied.
      def move_to(target_path)
        target = copy_to(target_path, convert: false)
        delete
        target
      end

      # Make S3 perform direct copies within S3 itself.
      def copy_to(target_path, convert: true, **args)
        return super if convert || (size.to_i >= S3_COPY_OBJECT_SIZE_LIMIT)

        target = IOStreams.new(target_path)
        return super(target, convert: convert, **args) unless target.is_a?(self.class)

        warn_unconverted_copy_options(args[:mode], args.except(:mode))
        authorize!
        target.authorize!
        source_name = Utils::PathName.join(bucket_name, path)
        client.copy_object(options.merge(bucket: target.bucket_name, key: target.path, copy_source: source_name))
        target
      end

      # Make S3 perform direct copies within S3 itself.
      def copy_from(source_path, convert: true, **args)
        return super(source_path, convert: true, **args) if convert

        source = IOStreams.new(source_path)
        if !source.is_a?(self.class) || (source.size.to_i >= S3_COPY_OBJECT_SIZE_LIMIT)
          return super(source, convert: convert, **args)
        end

        warn_unconverted_copy_options(args[:mode], args.except(:mode))
        authorize!
        source.authorize!
        source_name = Utils::PathName.join(source.bucket_name, source.path)
        client.copy_object(options.merge(bucket: bucket_name, key: path, copy_source: source_name))
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
        client.head_object(bucket: bucket_name, key: path).content_length
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
          client.get_object(options.merge(response_target: file, bucket: bucket_name, key: path))
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
          obj.upload_file(file_name, options)
        else
          ::File.open(file_name, "rb") do |file|
            client.put_object(options.merge(bucket: bucket_name, key: path, body: file))
          end
        end
      end

      # Notes:
      # - Currently all S3 lookups are recursive as of the pattern regardless of whether the pattern includes `**`.
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        authorize!
        matcher = Matcher.new(self, pattern, case_sensitive: case_sensitive, hidden: hidden)

        # When the pattern includes an exact file name without any pattern characters
        if matcher.pattern.nil?
          yield(matcher.path) if allowed_child?(matcher.path) && matcher.path.exist?
          return
        end

        prefix = Utils::URI.new(matcher.path.to_s).path.sub(%r{\A/}, "")
        each_object(prefix) do |name, object|
          next if !directories && object.key.end_with?("/")

          file_name = Utils::PathName.join("s3://", name, object.key)
          next unless matcher.match?(file_name)

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

      # Lazy load S3 client since it takes two seconds to create itself!
      def client
        @client ||= ::Aws::S3::Client.new(@client_options)
      end

      private

      # Reports a deprecation warning for each part of the url that this path cannot use, which IOStreams 3.0 raises
      # ArgumentError for when the path is created, so that a mistake in a configured url is reported wherever the
      # code runs: a url without a bucket, a fragment, which an unencoded `#` starts, and which is not part of the key, a
      # port, and a user name or password, which are ignored.
      def warn_unusable_url(uri)
        warn_url("it names no bucket, name one, such as 's3://bucket/#{path}'") if bucket_name.to_s.empty?
        if uri.fragment
          warn_url("it has a fragment, which a '#' starts, and which is not part of the key, percent-encode a '#' in a " \
                   "key as '%23'")
        end
        if uri.port
          warn_url("its port is ignored, supply the endpoint of another service that implements the S3 API with " \
                   "client: {endpoint: \"https://host:port\"}")
        end
        return unless uri.user || uri.password

        warn_url("its user name and password are ignored, supply the credentials with access_key_id: and " \
                 "secret_access_key:")
      end

      # Reports that the S3 url of this path is deprecated, since IOStreams 3.0 raises ArgumentError for it, for the
      # supplied reason.
      def warn_url(reason)
        Deprecation.warn("the S3 url #{warning_url} is deprecated, since #{reason}")
      end

      # Returns [String] the url of this path as a deprecation warning names it, quoted: its bucket and its key, without
      # the parts of the url that the path cannot use, such as a user name, and with an empty bucket kept, unlike #to_s,
      # such as `"s3:///a.csv"`.
      def warning_url
        Utils.display_text("s3://#{bucket_name}/#{path}").inspect
      end

      # Reports a deprecation warning for the region and credentials supplied with an `Aws::S3::Client`, which ignores
      # them, since it has its own, and which IOStreams 3.0 raises ArgumentError for when the path is created.
      def warn_client_arguments(client, **arguments)
        return if client.nil? || client.is_a?(Hash)

        names = arguments.compact.keys
        return if names.empty?

        words = Deprecation::Words.new(names)
        Deprecation.warn("#{words.keywords} #{words.are} deprecated with an Aws::S3::Client as client:, which ignores " \
                         "#{words.them}, since it has its own, supply #{words.them} to Aws::S3::Client.new instead, or " \
                         "supply client: as a Hash of its options")
      end

      # Reports a deprecation warning for the options of this path that IOStreams 3.0 raises ArgumentError for when the
      # path is created, see #unusable_option_names: one that the path sets itself, such as `key:`, which it overrides,
      # and one that no S3 request takes, such as a misspelled one, which the AWS SDK raises for once the path is used.
      def warn_unusable_options(names)
        unusable_option_names(names).each_pair do |set_by_path, unusable|
          words = Deprecation::Words.new(unusable)
          warn_unusable("the S3 #{words.one? ? 'option' : 'options'} #{words.keywords}", words, set_by_path)
        end
      end

      # Reports a deprecation warning for the names in the query of the url of this path that IOStreams 3.0 raises
      # ArgumentError for when the path is created, as for an option, see #warn_unusable_options. A name without a
      # value is more likely part of a key, such as the `?` of `s3://bucket/data/file?.csv`, so the warning then also
      # says how to write a `?` in a key.
      def warn_unusable_query(query)
        unusable_option_names(query.keys.map(&:to_sym)).each_pair do |set_by_path, unusable|
          names  = unusable.map(&:to_s)
          words  = Deprecation::Words.new(names)
          encode = ", and percent-encode a '?' in a key as '%3F'" if names.any? { |name| query[name].to_s.empty? }
          warn_unusable("#{words.keywords} in the query of the S3 url #{warning_url}", words, set_by_path, encode)
        end
      end

      # Returns [Hash<true|false, Array>] the supplied names of options that IOStreams 3.0 raises ArgumentError for: by
      # whether the path sets them itself (true), see PATH_PARAMETERS, or no S3 request of a path takes them (false),
      # see .known_option_names, without either when there are none.
      def unusable_option_names(names)
        set_by_path = names & PATH_PARAMETERS
        {true => set_by_path, false => names - set_by_path - self.class.known_option_names}.reject { |_, list| list.empty? }
      end

      # Reports that the options, which the subject names, and the words are about, see `IOStreams::Deprecation::Words`,
      # are deprecated, since the path sets them itself, or since no S3 request takes them, followed by the supplied
      # advice.
      def warn_unusable(subject, words, set_by_path, advice = nil)
        them   = words.them
        reason =
          if set_by_path
            "the path sets #{them} itself, and overrides #{them}, so remove #{them}"
          else
            "no S3 request takes #{them}, so correct or remove #{them}"
          end
        Deprecation.warn("#{subject} #{words.are} deprecated, since #{reason}#{advice}")
      end

      # Returns [Array(Array<Symbol>, String)|nil] the methods of the IO that v3.0 reads the object from, in place of the
      # temp File that v2.2 downloads it into, and its name, see `IOStreams::Stream#v3_source`: v3.0 reads the object as
      # the application reads it, with an IO that only reads, unless the `range` or `part_number` option chooses the
      # bytes to read, which it still downloads into a temp file.
      def v3_source
        return if options.key?(:range) || options.key?(:part_number)

        [IOStreams::Reader::V3_READ_METHODS, "the IO of an S3 path"]
      end

      # The methods of the IO that v3.0 uploads the object with, see #v3_target: those of an IO that write, and #flush.
      V3_UPLOAD_METHODS = [*IOStreams::Writer::V3_WRITE_METHODS, :flush].freeze
      private_constant :V3_UPLOAD_METHODS

      # The options that describe the whole object, with which v3.0 still writes the object into a temp file first, as
      # does a checksum of its data, such as `checksum_crc32`, see #v3_target.
      V3_WHOLE_OBJECT_OPTIONS = %i[content_length content_md5 write_offset_bytes].freeze
      private_constant :V3_WHOLE_OBJECT_OPTIONS

      # Returns [Array(Array<Symbol>, String)|nil] the methods of the IO that v3.0 uploads the object with, in place of the
      # temp File that v2.2 writes it into, and its name, see `IOStreams::Stream#v3_target`: v3.0 uploads the object as
      # the application writes it, with an IO that only writes, unless an option describes the whole object, which it
      # still writes into a temp file first. v3.0 writes the object with only the options that `put_object` takes, so
      # only those decide, rather than one that only another request takes, such as `checksum_mode` when reading.
      def v3_target
        put_object   = ::Aws::S3::Client.api.operation(:put_object).input.shape
        whole_object = options.each_key.any? do |name|
          put_object.member?(name) &&
            (V3_WHOLE_OBJECT_OPTIONS.include?(name) || (name.start_with?("checksum_") && name != :checksum_algorithm))
        end
        [V3_UPLOAD_METHODS, "the IO of an S3 path"] unless whole_object
      end

      # Yields the bucket name and each object in the bucket whose key starts with the supplied prefix.
      def each_object(prefix)
        token = nil
        loop do
          # Fetches upto 1,000 entries at a time
          resp = client.list_objects_v2(bucket: bucket_name, prefix: prefix, continuation_token: token)
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
      # The child uses this path's client, so that it has the same credentials and region.
      def child_path(bucket_name, key)
        child = self.class.new("s3://#{bucket_name}", client: client)
        child.replace_path(key.dup.freeze)
      end
    end
  end
end
