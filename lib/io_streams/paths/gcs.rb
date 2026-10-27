# frozen_string_literal: true

module IOStreams
  module Paths
    # A Google Cloud Storage object, named by its bucket and its name, `gs://bucket/exports/daily.csv`.
    #
    # Experimental: its options and behavior may still change, see docs/path.md.
    #
    # Cloud Storage implements the S3 API, so a `gs://` path makes its requests with the AWS SDK and an HMAC key of
    # Cloud Storage, and reads, writes, lists, copies and deletes an object as an S3 path does, see
    # `IOStreams::Paths::S3`. It differs from an S3 path in what Cloud Storage needs, and in what it supports through
    # that API:
    # * The client connects to `https://storage.googleapis.com`, with the bucket in the path of each request, so that
    #   the name of a bucket that has a `.` does not have to match the certificate of a host, and signs each request
    #   in the region `auto`, as Google's examples do.
    # * The AWS SDK adds a checksum to a request, and asks for one in its response, only when its operation requires
    #   one, as older versions did, rather than for every request, as newer versions do by default, which not every
    #   service that implements the S3 API supports.
    # * Its options are the metadata of an object that Cloud Storage keeps, see OPTION_NAMES, rather than every option
    #   of the AWS SDK's requests, most of which mean something only to S3, such as `request_payer:`.
    # * It has no `region:` argument, since Cloud Storage finds the location of a bucket itself.
    class GCS < S3
      URL_SCHEME = "gs"

      # The endpoint of the API of Cloud Storage that implements the S3 API.
      ENDPOINT = "https://storage.googleapis.com"

      # The options of the requests, which Cloud Storage keeps as the metadata of an object that is written.
      OPTION_NAMES = %i[
        cache_control content_disposition content_encoding content_language content_type metadata storage_class
      ].freeze

      # The settings of newer versions of the AWS SDK that compute and check the checksums of the requests only when
      # their operation requires one.
      CHECKSUM_SETTINGS = {request_checksum_calculation: "when_required", response_checksum_validation: "when_required"}.freeze

      # The error codes of Cloud Storage, other than those of S3, see `S3::Failure`, that mean the request has no
      # valid credentials.
      PERMISSION_DENIED_CODES = %w[
        AuthenticationRequired AuthenticationRequiredRequesterPays InvalidAuthentication InvalidSecurity
      ].freeze

      # The secret of the HMAC key, also within `client:`, see IOStreams::Path.redact_options.
      def self.sensitive_option_names = %i[secret_access_key]

      # Arguments:
      #
      # url: [String]
      #   `gs://`, the name of the bucket, `/`, and the name of the object.
      #   Examples:
      #     gs://my-bucket/file_name.txt
      #     gs://my-bucket/some_path/file_name.csv
      #
      #   Any query string in the url supplies options, see below, for example:
      #     gs://my-bucket/file_name.csv?content_type=text/csv
      #
      #   SECURITY WARNING:
      #     Do not interpolate untrusted file names into the url, since a name such as `file.csv?content_type=text/html`
      #     would set options. Instead join untrusted names onto the path, which does not parse them as a query:
      #       IOStreams.path("gs://my-bucket/uploads").join(untrusted_name)
      #
      # access_key_id: [String]
      #   The access id of the HMAC key of Cloud Storage to sign the requests with.
      #
      # secret_access_key: [String]
      #   The secret of the HMAC key.
      #
      # client: [Aws::S3::Client | Hash]
      #   The AWS S3 client to use for this path, which must be configured for Cloud Storage. Or, when a Hash, the
      #   options of a new client, which override those that Cloud Storage needs, such as `endpoint:`.
      #
      # Without credentials, the AWS SDK finds them in its environment, as for an S3 path, such as in the
      # `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables, or a profile of its credential files.
      #
      # Options, which apply when the object is written, or copied within Cloud Storage:
      #   cache_control:, content_disposition:, content_encoding:, content_language:, content_type: [String]
      #     The HTTP headers that Cloud Storage returns with the object.
      #   metadata: [Hash<String,String>]
      #     The custom metadata of the object.
      #   storage_class: [String]
      #     The storage class of the object, such as `NEARLINE`. Defaults to the storage class of the bucket.
      #
      # Any other option raises ArgumentError.
      def initialize(url, client: nil, access_key_id: nil, secret_access_key: nil, **args)
        # Before S3 takes `region:` as its argument.
        check_options!(args.keys)
        super
      end

      private

      def store_label = "GCS"

      def store_article = "a"

      # Returns [Hash] the options of a new client that connects to Cloud Storage. Load the AWS SDK first, see
      # `Sdk.load`.
      def client_defaults
        defaults = {endpoint: ENDPOINT, region: "auto", force_path_style: true}
        CHECKSUM_SETTINGS.each { |name, value| defaults[name] = value if Sdk.client_option?(name) }
        defaults
      end

      # Returns [Array<Symbol>] the supplied option names that are not OPTION_NAMES, which are known without the AWS SDK.
      def unknown_options(names)
        names - OPTION_NAMES
      end

      # Returns [Module] the kind of failure that an exception raised by Cloud Storage means, see `S3::Failure.kind`,
      # and PERMISSION_DENIED_CODES.
      def failure_kind(exception)
        super || (Errors::PermissionDenied if permission_denied?(exception))
      end

      # The AWS SDK is loaded when it is first needed, so before then no exception is one of its errors.
      def permission_denied?(exception)
        defined?(::Aws::S3::Errors) && exception.is_a?(::Aws::S3::Errors::ServiceError) &&
          PERMISSION_DENIED_CODES.include?(exception.code)
      end
    end
  end
end
