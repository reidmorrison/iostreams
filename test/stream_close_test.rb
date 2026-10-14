# frozen_string_literal: true

require_relative "test_helper"

# A stream never closes the IO supplied to it, which belongs to the caller.
class StreamCloseTest < Minitest::Test
  describe "the IO supplied to a stream" do
    let(:data) { "id,name\n1,Jack\n" }

    # Options needed to write and read each stream that has both a reader and a writer.
    stream_options = {pgp: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}]}
    stream_options[:gpg] = stream_options[:pgp]
    stream_options[:encode] = [{encoding: "UTF-8"}, {encoding: "UTF-8"}]

    # Every stream registered for a file name extension, and the built-in encode stream.
    IOStreams.extensions.merge(encode: IOStreams::Encode).each_pair do |name, extension|
      next unless extension.reader_class && extension.writer_class

      writer_options, reader_options = stream_options.fetch(name, [{}, {}])
      # Applies only this stream: the built-in encode stream with #encoding, and any other with #stream.
      apply = ->(stream, options) { name == :encode ? stream.encoding(**options) : stream.stream(name, **options) }

      it "is not closed by the #{name.inspect} writer or reader" do
        output = StringIO.new(+"")
        apply.call(IOStreams.stream(output), writer_options).writer { |io| io.write(data) }

        refute_predicate output, :closed?

        input = StringIO.new(output.string)
        result = apply.call(IOStreams.stream(input), reader_options).reader(&:read)

        refute_predicate input, :closed?
        assert_equal data, result
      end
    end
  end
end
