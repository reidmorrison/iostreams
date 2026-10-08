module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # The kind of failure, such as `IOStreams::Errors::NotFound`, that an exception raised by the AWS SDK means,
      # see `IOStreams::Errors::StorageError`.
      module Failure
        # The S3 error codes that mean the object, or its bucket, does not exist. A HEAD request, such as `#exist?`,
        # has no response body, so its code is `NotFound`.
        NOT_FOUND_CODES = %w[NoSuchBucket NoSuchKey NoSuchVersion NotFound].freeze

        # The S3 error codes that mean the request is not permitted, or its credentials are not valid. A HEAD request
        # has no response body, so its code is `Forbidden`.
        #
        # Without the `s3:ListBucket` permission, S3 responds to a request for a key that does not exist with
        # `AccessDenied`, or `Forbidden`, rather than `NoSuchKey`.
        PERMISSION_DENIED_CODES = %w[
          AccessDenied AccountProblem AllAccessDisabled ExpiredToken Forbidden InvalidAccessKeyId InvalidToken
          SignatureDoesNotMatch
        ].freeze

        # The S3 error codes, and the HTTP statuses, that mean S3 could not handle the request at the time, once the
        # AWS SDK has retried it. A HEAD request has no response body, so its code is its status, such as `Http503Error`.
        UNAVAILABLE_CODES    = %w[InternalError RequestTimeout ServiceUnavailable SlowDown].freeze
        UNAVAILABLE_STATUSES = [429, 500, 502, 503, 504].freeze

        # Returns [Module] the kind of failure that an exception raised by the AWS SDK means, or nil when it is none of
        # them.
        def self.kind(exception)
          case exception
          when Aws::S3::Errors::ServiceError
            service_kind(exception)
          when Aws::Errors::MissingCredentialsError, Aws::Sigv4::Errors::MissingCredentialsError
            Errors::PermissionDenied
          when Seahorse::Client::NetworkingError
            # S3 could not be reached, once the AWS SDK has retried the request.
            Errors::Unavailable
          when Aws::S3::MultipartUploadError
            # Raised once the upload of a part fails, with the failure of each part.
            kind(exception.errors.first) if exception.errors.first
          end
        end

        # Returns [Module] the kind of failure that the error code, or the status, of an S3 response means.
        def self.service_kind(exception)
          code = exception.code
          if NOT_FOUND_CODES.include?(code)
            Errors::NotFound
          elsif PERMISSION_DENIED_CODES.include?(code)
            Errors::PermissionDenied
          elsif UNAVAILABLE_CODES.include?(code) || UNAVAILABLE_STATUSES.include?(exception.context&.http_response&.status_code)
            Errors::Unavailable
          end
        end
        private_class_method :service_kind
      end
    end
  end
end
