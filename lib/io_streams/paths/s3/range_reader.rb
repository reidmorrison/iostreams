module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # Reads an S3 object from its start to its end, one range at a time as the caller reads it, in the caller's
      # thread, so that the object is not downloaded into a temp file first, and only one range is held in memory.
      #
      # Every range after the first is read from the same object as the first, by its version id, or by its ETag when
      # the bucket is not versioned, so that an object replaced while it is read raises
      # `Aws::S3::Errors::PreconditionFailed`, rather than returning parts of both.
      #
      # Used internally by the S3 path, which makes each `get_object` request, so that it supplies its bucket, key and
      # options, and tags each failure.
      class RangeReader
        include ChunkReader

        # The number of bytes requested at a time.
        RANGE_SIZE = 8 * 1024 * 1024

        # Options that choose the bytes of the object to read, which a range would replace.
        RANGE_OPTIONS = %i[range part_number].freeze

        # Returns [true|false] whether the object can be read by ranges with these `get_object` options.
        def self.supports?(option_names)
          !option_names.intersect?(RANGE_OPTIONS)
        end

        # Parameters:
        #   request: [Proc]
        #     Makes a `get_object` request for the object with the supplied parameters, and returns its response.
        def initialize(request, range_size: RANGE_SIZE)
          @request    = request
          @range_size = range_size
          @position   = 0
          @size       = nil
          @same       = {}
        end

        def closed?
          false
        end

        private

        # Requests the next range. Returns [String] the range, or nil at the end of the object, see `ChunkReader`.
        def next_chunk
          return if @size && @position >= @size

          response  = request_range
          range     = response.body.read.force_encoding(Encoding::BINARY)
          @position += range.bytesize
          @size ||= total_size(response)
          return range unless range.empty?
          # Rather than ending the object early.
          raise(Errors::CommunicationsFailure, "S3 returned no data at byte #{@position} of #{@size}") if @position < @size
        end

        # The path loads the AWS SDK before it reads, see `Sdk.load`.
        def request_range
          first     = @size.nil?
          last_byte = @position + @range_size - 1
          response  =
            begin
              @request.call(range: "bytes=#{@position}-#{last_byte}", **@same)
            rescue Aws::S3::Errors::InvalidRange
              raise unless first

              # S3 cannot return a range of an empty object.
              @request.call
            end
          @same = response.version_id ? {version_id: response.version_id} : {if_match: response.etag}.compact if first
          response
        end

        # Returns [Integer] the size of the object, from the first response, such as `bytes 0-8388607/20971520`. A
        # response without a range holds the whole object.
        def total_size(response)
          total = response.content_range&.split("/")&.last
          total && total != "*" ? Integer(total) : @position
        end
      end
    end
  end
end
