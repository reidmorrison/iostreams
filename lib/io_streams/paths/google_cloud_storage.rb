require "uri"

module IOStreams
  module Paths
    class GoogleCloudStorage < IOStreams::Path
      attr_reader :bucket_name, :storage

      def initialize(url, **args)
        Utils.load_soft_dependency("google-cloud-storage", "Google Cloud Storage") unless defined?(::Google::Cloud::Storage)

        uri = Utils::URI.new(url)
        raise "Invalid URI. Required Format: 'gs://<bucket_name>/<key>'" unless uri.scheme == "gs"

        @bucket_name = uri.hostname
        key          = uri.path.sub(%r{\A/}, "")

        @storage = Google::Cloud::Storage.new(**args)

        super(key)
      end

      def to_s
        ::File.join("gs://", bucket_name, path)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      # def delete
      #   client.delete_object(bucket: bucket_name, key: path)
      #   self
      # rescue Aws::S3::Errors::NotFound
      #   self
      # end
      #
      # def exist?
      #   client.head_object(bucket: bucket_name, key: path)
      #   true
      # rescue Aws::S3::Errors::NotFound
      #   false
      # end

      # Moves this file to the `target_path` by copying it to the new name and then deleting the current file.
      #
      # Notes:
      # - Can copy across buckets.
      # - No stream conversions are applied.
      # def move_to(target_path)
      #   target = copy_to(target_path, convert: false)
      #   delete
      #   target
      # end

      # Make S3 perform direct copies within S3 itself.
      # def copy_to(target_path, convert: true, **args)
      #   return super(target_path, convert: convert, **args) if convert || (size.to_i >= S3_COPY_OBJECT_SIZE_LIMIT)
      #
      #   target = IOStreams.new(target_path)
      #   return super(target, convert: convert, **args) unless target.is_a?(self.class)
      #
      #   source_name = ::File.join(bucket_name, path)
      #   client.copy_object(options.merge(bucket: target.bucket_name, key: target.path, copy_source: source_name))
      #   target
      # end

      # Make S3 perform direct copies within S3 itself.
      # def copy_from(source_path, convert: true, **args)
      #   return super(source_path, convert: true, **args) if convert
      #
      #   source = IOStreams.new(source_path)
      #   if !source.is_a?(self.class) || (source.size.to_i >= S3_COPY_OBJECT_SIZE_LIMIT)
      #     return super(source, convert: convert, **args)
      #   end
      #
      #   source_name = ::File.join(source.bucket_name, source.path)
      #   client.copy_object(options.merge(bucket: bucket_name, key: path, copy_source: source_name))
      # end

      # GCS logically creates paths when a key is set.
      def mkpath
        self
      end

      def mkdir
        self
      end

      # def size
      #   client.head_object(bucket: bucket_name, key: path).content_length
      # rescue Aws::S3::Errors::NotFound
      #   nil
      # end

      # TODO: delete_all

      # Read from AWS S3 file.
      def stream_reader(&block)
        # Since GCS download only supports a push stream, write it to a tempfile first.
        Utils.temp_file_name("iostreams_gs") do |file_name|
          read_file(file_name)

          ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      # def read_file(file_name)
      #   ::File.open(file_name, "wb") do |file|
      #     client.get_object(options.merge(response_target: file, bucket: bucket_name, key: path))
      #   end
      # end

      # Write to GCS
      #
      # Raises [MultipartUploadError] If an object is being uploaded in
      #   parts, and the upload can not be completed, then the upload is
      #   aborted and this error is raised.  The raised error has a `#errors`
      #   method that returns the failures that caused the upload to be
      #   aborted.
      def stream_writer(&block)
        # Since GCS upload only supports a pull stream, write it to a tempfile first.
        Utils.temp_file_name("iostreams_gs") do |file_name|
          result = ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }

          # Upload file only once all data has been written to it
          write_file(file_name)
          result
        end
      end

      # Shortcut method if caller has a filename already with no other streams applied:
      def write_file(file_name)
        # if ::File.size(file_name) > MULTIPART_UPLOAD_SIZE
        #   # Use multipart file upload
        #   s3  = Aws::S3::Resource.new(client: client)
        #   obj = s3.bucket(bucket_name).object(path)
        #   obj.upload_file(file_name, options)
        # else
          ::File.open(file_name, "rb") do |file|
            client.put_object(options.merge(bucket: bucket_name, key: path, body: file))
          end
        # end
      end

      # Notes:
      # - Currently all S3 lookups are recursive as of the pattern regardless of whether the pattern includes `**`.
      # def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false)
      #   unless block_given?
      #     return to_enum(__method__, pattern,
      #                    case_sensitive: case_sensitive, directories: directories, hidden: hidden)
      #   end
      #
      #   matcher = Matcher.new(self, pattern, case_sensitive: case_sensitive, hidden: hidden)
      #
      #   # When the pattern includes an exact file name without any pattern characters
      #   if matcher.pattern.nil?
      #     yield(matcher.path) if matcher.path.exist?
      #     return
      #   end
      #
      #   prefix = Utils::URI.new(matcher.path.to_s).path.sub(%r{\A/}, "")
      #   token  = nil
      #   loop do
      #     # Fetches upto 1,000 entries at a time
      #     resp = client.list_objects_v2(bucket: bucket_name, prefix: prefix, continuation_token: token)
      #     resp.contents.each do |object|
      #       next if !directories && object.key.end_with?("/")
      #
      #       file_name = ::File.join("s3://", resp.name, object.key)
      #       next unless matcher.match?(file_name)
      #
      #       yield(self.class.new(file_name), object.to_h)
      #     end
      #     token = resp.next_continuation_token
      #     break if token.nil?
      #   end
      #   nil
      # end

      # On GCS only files that are completely saved are visible.
      def partial_files_visible?
        false
      end

      # Lazy load S3 client since it takes two seconds to create itself!
      def client
        @client ||= ::Aws::S3::Client.new(@client_options)
      end
    end
  end
end
