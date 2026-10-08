require_relative "test_helper"

# The `:stream` mode reads bytes from every stream, like `File#read` on a file opened in binary mode,
# so that the same data reads the same way whichever streams it is stored with.
class StreamBytesTest < Minitest::Test
  describe "reading the whole stream in the :stream mode" do
    let(:data) { "id,name\n1,José\n" }

    # Options needed to write and read each stream that has both a reader and a writer.
    stream_options = {pgp: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}]}
    stream_options[:gpg] = stream_options[:pgp]
    stream_options[:enc] = [{compress: true}, {}]

    IOStreams.extensions.each_pair do |name, extension|
      next unless extension.reader_class && extension.writer_class

      writer_options, reader_options = stream_options.fetch(name, [{}, {}])

      it "returns bytes from the #{name.inspect} reader" do
        output = StringIO.new(+"")
        IOStreams.stream(output).stream(name, **writer_options).writer { |io| io.write(data) }

        result = IOStreams.stream(StringIO.new(output.string)).stream(name, **reader_options).reader(&:read)

        assert_equal Encoding::BINARY, result.encoding
        assert_equal data.b, result
      end
    end

    it "returns bytes from an uncompressed :enc reader" do
      output = StringIO.new(+"")
      IOStreams.stream(output).stream(:enc, compress: false).writer { |io| io.write(data) }

      result = IOStreams.stream(StringIO.new(output.string)).stream(:enc).reader(&:read)

      assert_equal Encoding::BINARY, result.encoding
    end
  end
end
