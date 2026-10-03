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

  def get_object(params)
    data = objects[[params[:bucket], params[:key]]]
    return "NoSuchKey" unless data

    {body: data, content_length: data.bytesize}
  end

  def head_object(params)
    data = objects[[params[:bucket], params[:key]]]
    return "NotFound" unless data

    {content_length: data.bytesize}
  end

  def delete_object(params)
    objects.delete([params[:bucket], params[:key]])
    {}
  end

  # `copy_source` is "<bucket>/<key>".
  def copy_object(params)
    bucket, key = params[:copy_source].split("/", 2)
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
