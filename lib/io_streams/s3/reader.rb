module IOStreams
  module S3
    class Reader
      # Read from a AWS S3 file
      def self.open(uri = nil, bucket: nil, region: nil, key: nil, &block)
        options = uri.nil? ? args : parse_uri(uri).merge(args)
        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        object  = s3.bucket(options[:bucket]).object(options[:key])

        IO.pipe do |read_io, write_io|
          object.get(response_target: write_io)
          write_io.close
          block.call(read_io)
        end
      end

      def self.open2(uri = nil, **args, &block)
        if !uri.nil? && IOStreams.reader_stream?(uri)
          raise(ArgumentError, 'S3 can only accept a URI, not an IO stream when reading.')
        end

        unless defined?(Aws::S3::Resource)
          begin
            require 'aws-sdk-s3'
          rescue LoadError => exc
            raise(LoadError, "Install gem 'aws-sdk-s3' to read and write AWS S3 files: #{exc.message}")
          end
        end

        options = uri.nil? ? args : parse_uri(uri).merge(args)

        begin
          io = new(**options)
          block.call(io)
        ensure
          io.close if io && (io.respond_to?(:closed?) && !io.closed?)
        end
      end

      def initialize(region: nil, bucket:, key:)
        s3      = region.nil? ? Aws::S3::Resource.new : Aws::S3::Resource.new(region: region)
        @object = s3.bucket(bucket).object(key)
        @buffer = []
      end

      def read(length = nil, outbuf = nil)
        # Sufficient data already in the buffer
        return @buffer.slice!(0, length) if length && (length <= @buffer.length)

        # Fetch in chunks
        @object.get do |chunk|
          @buffer << chunk
          return @buffer.slice!(0, length) if length && (length <= @buffer.length)
        end
        @buffer if @buffer.size > 0
      end

      private

      attr_reader :object

    end
  end
end
