module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # The kind of failure, such as `IOStreams::Errors::NotFound`, that an exception raised by the AWS SDK means,
      # see `IOStreams::Errors::StorageError`.
      module Failure
        # The S3 error codes that mean the object, or its bucket, does not exist. A HEAD request, such as `#exist?`,
        # has no response body, so its code is `NotFound`.
        NOT_FOUND_CODES = %w[NoSuchBucket NoSuchKey NoSuchVersion NotFound].freeze

        # Returns [Module] the kind of failure that an exception raised by the AWS SDK means, or nil when it is none of
        # them.
        def self.kind(exception)
          case exception
          when Aws::S3::Errors::ServiceError
            service_kind(exception)
          when Aws::S3::MultipartUploadError
            # Raised once the upload of a part fails, with the failure of each part.
            kind(exception.errors.first) if exception.errors.first
          end
        end

        # Returns [Module] the kind of failure that the error code of an S3 response means.
        def self.service_kind(exception)
          Errors::NotFound if NOT_FOUND_CODES.include?(exception.code)
        end
        private_class_method :service_kind
      end
    end
  end
end
