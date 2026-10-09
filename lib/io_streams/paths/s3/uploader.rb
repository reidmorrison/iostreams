module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # Uploads what the block writes to an S3 object as it is written, so that it is not written into a temp file
      # first.
      #
      # Less than one part is stored with a single `put_object` request once the block completes. Otherwise the data is
      # uploaded in parts, a few at a time in other threads while the block writes the next part, and the object is
      # stored once the block completes. S3 only stores an object once its upload completes, so a partial object is
      # never visible. When the block raises, or a request fails, the upload is aborted, so that S3 discards the parts
      # already uploaded, and the exception is raised unchanged.
      #
      # S3 accepts at most 10,000 parts, so the size of a part starts at `PART_SIZE`, and doubles after every
      # `PARTS_PER_SIZE` parts, upto the largest part that S3 accepts. So an object of any size that S3 accepts, upto
      # 5TB, can be uploaded, while a smaller object holds less in memory.
      #
      # Used internally by the S3 path, which makes each request, so that it supplies its bucket, key and options, and
      # tags each failure.
      class Uploader
        # The size of the first parts, and the most that is stored with a single request.
        PART_SIZE = 8 * 1024 * 1024
        # The number of parts uploaded before the size of a part doubles.
        PARTS_PER_SIZE = 1_000
        # The largest part that S3 accepts.
        MAX_PART_SIZE = 5 * 1024 * 1024 * 1024
        # The number of parts uploaded at the same time.
        CONCURRENT_PARTS = 4

        # `put_object` options that describe the whole object or where to write it, which no part can be supplied.
        WHOLE_OBJECT_OPTIONS = %i[content_length content_md5 write_offset_bytes].freeze

        # Returns [true|false] whether what the block writes can be uploaded as it is written with these `put_object`
        # options, which is not the case for options that describe the whole object, such as its `content_md5` or a
        # checksum of its data.
        def self.supports?(option_names)
          option_names.none? { |name| WHOLE_OBJECT_OPTIONS.include?(name) || checksum_value?(name) }
        end

        # Returns [true|false] whether the option is the checksum of the whole object, such as `checksum_crc32`,
        # rather than `checksum_algorithm`, which chooses the checksum that S3 checks for each part.
        def self.checksum_value?(name)
          name.start_with?("checksum_") && name != :checksum_algorithm
        end
        private_class_method :checksum_value?

        # Yields an uploader to the block, which it writes the object to, and stores the object once the block
        # completes. Returns the result of the block.
        #
        # Parameters:
        #   request: [Proc]
        #     Makes the S3 request for the object, such as `:put_object`, with the supplied parameters, and returns its
        #     response.
        def self.upload(request)
          uploader = new(request)
          result   = yield(uploader)
          uploader.complete
          result
        rescue Exception # rubocop:disable Lint/RescueException
          # Including `Interrupt`, and the exception that `Timeout` raises within its block, so that S3 does not keep the
          # parts already uploaded.
          uploader&.abort
          raise
        end

        def initialize(request)
          @request    = request
          @buffer     = "".b
          @part_count = 0
          @uploads    = []
          @parts      = []
        end

        # Returns [Integer] the number of bytes written, like `IO#write`.
        def write(*data)
          data.sum { |item| append(item.to_s) }
        end

        def <<(data)
          append(data.to_s)
          self
        end

        def flush
          self
        end

        # Stores the object.
        def complete
          if @upload_id
            start_part(@buffer) unless @buffer.empty?
            finish_part until @uploads.empty?
            @request.call(:complete_multipart_upload, upload_id: @upload_id, multipart_upload: {parts: @parts})
          else
            @request.call(:put_object, body: @buffer)
          end
        end

        # Stops uploading parts, and aborts the upload, so that S3 discards the parts already uploaded.
        def abort
          @uploads.each(&:kill).each(&:join)
          @request.call(:abort_multipart_upload, upload_id: @upload_id) if @upload_id
        rescue StandardError => e
          # So that the exception that stopped the upload is raised, rather than this one.
          IOStreams.logger&.warn("Failed to abort the multipart upload #{@upload_id}, whose parts S3 keeps: #{e.message}")
        end

        private

        def append(data)
          @buffer << (data.encoding == Encoding::BINARY ? data : data.b)
          # Holds back the last part until it is complete, so that less than one part is stored with one request.
          while @buffer.bytesize > part_size
            size    = part_size
            part    = @buffer.byteslice(0, size)
            @buffer = @buffer.byteslice(size..)
            start_part(part)
          end
          data.bytesize
        end

        def part_size
          [PART_SIZE << (@part_count / PARTS_PER_SIZE), MAX_PART_SIZE].min
        end

        # Starts uploading the part in another thread, once fewer than `CONCURRENT_PARTS` parts are being uploaded.
        def start_part(data)
          unless @upload_id
            response   = @request.call(:create_multipart_upload)
            @upload_id = response.upload_id
            @checksum  = response.checksum_algorithm
          end
          finish_part while @uploads.size >= CONCURRENT_PARTS

          @part_count += 1
          number       = @part_count
          @uploads << Thread.new { upload_part(number, data) }
        end

        # Returns [Hash] the part once it is uploaded, or the exception that its upload raised, so that it is raised in
        # the caller's thread.
        def upload_part(number, data)
          response = @request.call(:upload_part, upload_id: @upload_id, part_number: number, body: data)
          part     = {etag: response.etag, part_number: number}
          # S3 checks the checksum of each part, in the algorithm of the upload, when the upload completes.
          part[:"checksum_#{@checksum.downcase}"] = response.public_send(:"checksum_#{@checksum.downcase}") if @checksum
          part
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end

        # Waits for the first part being uploaded, raising the exception that its upload raised.
        def finish_part
          part = @uploads.shift.value
          raise(part) if part.is_a?(Exception)

          @parts << part
        end
      end
    end
  end
end
