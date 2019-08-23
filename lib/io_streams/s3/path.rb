# frozen_string_literal: true
module IOStreams
  module S3
    class Path < IOStreams::BasePath
      def initialize(path)
        IOStreams::S3.load_dependencies
        @s3      = Aws::S3::Resource.new
        @options = IOStreams::S3.parse_uri(path)
        @object  = s3.bucket(options[:bucket]).object(options[:key])
        super(path)
      end

      # S3 logically creates paths when a key is set.
      def mkpath
        self
      end

      def mkdir
        self
      end

      def exist?
        object.exists?
      end

      def size
        object.size
      end

      def delete
        object.delete
        self
      end

      private

      attr_reader :s3, :options, :object
    end
  end
end
