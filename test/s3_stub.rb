require "digest"

# In-memory S3, built on the AWS SDK's response stubbing, so that the S3 path tests
# run without credentials or network calls.
#
# Applies to every S3 client created while installed, including those built internally,
# such as the clients for the children returned by `#each_child`.
#
# Example:
#   S3Stub.install
#   IOStreams.path("s3://bucket/test.txt").write("Hello")
#   S3Stub.uninstall
class S3Stub
  def self.install
    @previous = ::Aws.config[:s3]
    ::Aws.config[:s3] = (@previous || {}).merge(stub_responses: new.stub_responses)
  end

  def self.uninstall
    if @previous.nil?
      ::Aws.config.delete(:s3)
    else
      ::Aws.config[:s3] = @previous
    end
  end

  def initialize
    # Object data keyed by [bucket, key].
    @objects = {}
  end

  def stub_responses
    {
      put_object:      ->(context) { put_object(context.params) },
      get_object:      ->(context) { get_object(context.params) },
      head_object:     ->(context) { head_object(context.params) },
      delete_object:   ->(context) { delete_object(context.params) },
      delete_objects:  ->(context) { delete_objects(context.params) },
      copy_object:     ->(context) { copy_object(context.params) },
      list_objects_v2: ->(context) { list_objects_v2(context.params) }
    }
  end

  private

  attr_reader :objects

  def put_object(params)
    body = params[:body]
    data =
      if body.respond_to?(:read)
        body.rewind if body.respond_to?(:rewind)
        body.read
      else
        body.to_s
      end
    objects[[params[:bucket], params[:key]]] = data.b
    {}
  end

  # Returns the requested range of the object, such as "bytes=0-99", as S3 does, which cannot return a range of an
  # empty object.
  def get_object(params)
    data = objects[[params[:bucket], params[:key]]]
    return "NoSuchKey" unless data

    etag = etag(data)
    if params[:if_match] && params[:if_match] != etag
      return {status_code: 412, headers: {}, body: "<Error><Code>PreconditionFailed</Code></Error>"}
    end
    return {body: data, content_length: data.bytesize, etag: etag} unless params[:range]

    first, last = params[:range].delete_prefix("bytes=").split("-").map(&:to_i)
    return {status_code: 416, headers: {}, body: "<Error><Code>InvalidRange</Code></Error>"} if first >= data.bytesize

    part = data.byteslice(first..last)
    {body: part, content_length: part.bytesize, etag: etag, content_range: "bytes #{first}-#{first + part.bytesize - 1}/#{data.bytesize}"}
  end

  def etag(data)
    %("#{Digest::MD5.hexdigest(data)}")
  end

  def head_object(params)
    data = objects[[params[:bucket], params[:key]]]
    return "NotFound" unless data

    {content_length: data.bytesize, last_modified: Time.at(0).utc}
  end

  def delete_object(params)
    objects.delete([params[:bucket], params[:key]])
    {}
  end

  def delete_objects(params)
    params[:delete][:objects].each { |object| objects.delete([params[:bucket], object[:key]]) }
    {deleted: [], errors: []}
  end

  # `copy_source` is "<bucket>/<key>", with the key url-encoded.
  def copy_object(params)
    bucket, key = params[:copy_source].split("/", 2)
    key         = URI.decode_uri_component(key)
    data        = objects[[bucket, key]]
    return "NoSuchKey" unless data

    objects[[params[:bucket], params[:key]]] = data
    {copy_object_result: {}}
  end

  # Returns every matching key in a single page.
  def list_objects_v2(params)
    prefix   = params[:prefix].to_s
    contents = objects.keys.
               select { |bucket, key| bucket == params[:bucket] && key.start_with?(prefix) }.
               sort.
               map { |_, key| {key: key, size: objects[[params[:bucket], key]].bytesize} }
    {name: params[:bucket], prefix: prefix, contents: contents, key_count: contents.size, is_truncated: false}
  end
end
