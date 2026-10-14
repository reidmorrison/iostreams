# frozen_string_literal: true

require_relative "test_helper"

# The stream supplied to a reader or writer block behaves like an IO whichever streams the data uses, since a path is
# configuration, so that code that reads or writes a `.gz` file still works when the file name changes to `.bz2`.
class StreamIOTest < Minitest::Test
  # Options needed to write and read each stream.
  STREAM_OPTIONS = {
    pgp: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}],
    gpg: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}]
  }.freeze

  describe "the stream supplied to a writer block" do
    # Every stream registered for a file name extension that both writes and reads.
    IOStreams.extensions.each_pair do |name, format|
      next unless format.reader_class && format.writer_class

      writer_options, reader_options = STREAM_OPTIONS.fetch(name, [{}, {}])

      it "responds to the methods of an IO that write for the #{name.inspect} stream" do
        output = StringIO.new(+"".b)
        IOStreams.stream(output).stream(name, **writer_options).writer do |io|
          assert_equal 8, io.write("id,", "name\n")
          assert_same io, io << "1," << "Jack\n"
          assert_nil io.print("2,", "Jill\n")
          assert_nil io.puts("3,Bob", ["4,Ann"])
          assert_nil io.printf("%<id>d,%<name>s\n", id: 5, name: "Zoe")
        end

        result = IOStreams.stream(StringIO.new(output.string)).stream(name, **reader_options).read

        assert_equal "id,name\n1,Jack\n2,Jill\n3,Bob\n4,Ann\n5,Zoe\n", result
      end
    end

    it "responds to the methods of an IO that write for an uncompressed :enc stream" do
      output = StringIO.new(+"".b)
      IOStreams.stream(output).stream(:enc, compress: false).writer do |io|
        assert_equal 8, io.write("id,", "name\n")
        assert_same io, io << "1," << "Jack\n"
        assert_nil io.print("2,", "Jill\n")
        assert_nil io.puts("3,Bob", ["4,Ann"])
        assert_nil io.printf("%<id>d,%<name>s\n", id: 5, name: "Zoe")
      end

      assert_equal "id,name\n1,Jack\n2,Jill\n3,Bob\n4,Ann\n5,Zoe\n", IOStreams.stream(StringIO.new(output.string)).stream(:enc).read
    end
  end
end
