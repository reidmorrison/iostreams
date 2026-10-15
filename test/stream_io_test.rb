# frozen_string_literal: true

require_relative "test_helper"
require "csv"

# The stream supplied to a reader or writer block behaves like an IO whichever streams the data uses, since a path is
# configuration, so that code that reads or writes a `.gz` file still works when the file name changes to `.bz2`.
class StreamIOTest < Minitest::Test
  # Options needed to write and read each stream.
  STREAM_OPTIONS = {
    pgp: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}],
    gpg: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}]
  }.freeze

  describe "the stream supplied to a reader block" do
    # More than one block of the data that most streams decompress at a time.
    let(:data) { Array.new(5000) { |i| "#{i},#{'x' * 20}\n" }.join }

    # Yields the stream that reads the data, once it is written through the named stream.
    def read_back(name, writer_options, reader_options, &)
      output = StringIO.new(+"".b)
      IOStreams.stream(output).stream(name, **writer_options).write(data)
      IOStreams.stream(StringIO.new(output.string)).stream(name, **reader_options).reader(&)
    end

    def skip_unless_read_back(format)
      return unless defined?(JRuby) && format == IOStreams::Xlsx

      skip("creek on JRuby loses characters of the cells of a large worksheet")
    end

    # Every stream registered for a file name extension that both writes and reads.
    IOStreams.extensions.each_pair do |name, format|
      next unless format.reader_class && format.writer_class

      writer_options, reader_options = STREAM_OPTIONS.fetch(name, [{}, {}])

      it "reads parts of the data like an IO for the #{name.inspect} stream" do
        skip_unless_read_back(format)

        read_back(name, writer_options, reader_options) do |io|
          assert_equal "", io.read(0)
          refute_predicate io, :eof?

          buffer = +"data of an earlier read"

          assert_same buffer, io.read(10, buffer)
          assert_equal data[0, 10], buffer
          # Bytes, like the data read without a buffer, apart from a File, whose `#read` keeps the encoding of the buffer.
          assert_equal Encoding::BINARY, buffer.encoding unless io.is_a?(::File)

          part = io.readpartial(10)

          assert_includes 1..10, part.bytesize
          assert_equal data[10, part.bytesize], part

          offset = 10 + part.bytesize
          block  = io.read(70_000)

          assert_equal Encoding::BINARY, block.encoding
          assert_equal data[offset, 70_000], block
          assert_equal data[(offset + 70_000)..], io.read
        end
      end

      it "reads lines like an IO for the #{name.inspect} stream" do
        skip_unless_read_back(format)

        read_back(name, writer_options, reader_options) do |io|
          assert_equal "0,#{'x' * 20}\n", io.gets
          assert_equal "1,#{'x' * 20}", io.gets(chomp: true)
          assert_equal "2,", io.gets(",")

          lines = []
          io.each_line { |line| lines << line }

          assert_equal data.lines[2..].join, "2,#{lines.join}"
          assert_nil io.gets
          assert_raises(EOFError) { io.readline }
        end
      end

      it "reads the rest of the lines like IO#readlines for the #{name.inspect} stream" do
        skip_unless_read_back(format)

        read_back(name, writer_options, reader_options) do |io|
          assert_equal "0,#{'x' * 20}\n", io.gets
          assert_equal data.lines[1..], io.readlines
          assert_empty io.readlines
        end
      end

      it "is read by CSV for the #{name.inspect} stream, as an IO is" do
        skip_unless_read_back(format)

        rows = read_back(name, writer_options, reader_options) { |io| CSV.new(io).to_a }

        assert_equal 5000, rows.size
        assert_equal ["4999", "x" * 20], rows.last
      end

      it "reads the end of the data like an IO for the #{name.inspect} stream" do
        skip_unless_read_back(format)

        read_back(name, writer_options, reader_options) do |io|
          assert_equal data, io.read
          assert_predicate io, :eof?

          buffer = +"data of an earlier read"

          assert_nil io.read(10)
          assert_nil io.read(10, buffer)
          assert_empty buffer
          assert_equal "", io.read
          assert_raises(EOFError) { io.readpartial(10) }
        end
      end
    end

    # The encode stream, applied with #encoding, reads text, so what it reads is in the encoding of the text, rather
    # than bytes, and in whole characters.
    describe "with an encoding" do
      # More than one block of the data that the encode stream reads at a time, with characters of two bytes, so that
      # the blocks split them.
      let(:text) { Array.new(5000) { |i| "#{i},caf\u00e9 na\u00efve\n" }.join }

      # The encoding of the data and the stream that it is within, for: text that the encode stream checks, text that it
      # converts, and text that it reads from another stream.
      {
        "UTF-8"              => ["UTF-8", "UTF-8", nil],
        "Windows-1252:UTF-8" => ["Windows-1252:UTF-8", "Windows-1252", nil],
        "UTF-8 within a .gz" => ["UTF-8", "UTF-8", :gz]
      }.each_pair do |description, (encoding, external, stream)|
        # Yields the stream that reads the text, once it is written in the external encoding, within the stream.
        define_method(:read_text) do |&block|
          output = StringIO.new(+"".b)
          (stream ? IOStreams.stream(output).stream(stream) : IOStreams.stream(output).raw).write(text.encode(external).b)
          input = IOStreams.stream(StringIO.new(output.string))
          input = input.stream(stream) if stream
          input.encoding(encoding).reader(&block)
        end

        it "reads parts of the text like an IO for #{description}" do
          read_text do |io|
            assert_equal ["", Encoding::UTF_8], [io.read(0), io.read(0).encoding]
            refute_predicate io, :eof?

            buffer = +"data of an earlier read"

            assert_same buffer, io.read(10, buffer)
            assert_equal text.byteslice(0, 10), buffer
            assert_equal Encoding::UTF_8, buffer.encoding

            part = io.readpartial(10)

            assert_includes 1..10, part.bytesize
            assert_equal text.byteslice(10, part.bytesize), part

            # Whole characters, upto the length.
            offset = 10 + part.bytesize
            block  = io.read(70_000)

            assert_equal Encoding::UTF_8, block.encoding
            assert_equal text.byteslice(offset, 70_000).scrub(""), block
            assert_equal text.byteslice((offset + block.bytesize)..), io.read
          end
        end

        it "reads lines like an IO for #{description}" do
          read_text do |io|
            assert_equal "0,caf\u00e9 na\u00efve\n", io.gets
            assert_equal "1,caf\u00e9 na\u00efve", io.gets(chomp: true)
            assert_equal "2,", io.gets(",")

            lines = []
            io.each_line { |line| lines << line }

            assert_equal text.lines[2..].join, "2,#{lines.join}"
            assert_nil io.gets
            assert_raises(EOFError) { io.readline }
          end
        end

        it "reads the rest of the lines like IO#readlines for #{description}" do
          read_text do |io|
            assert_equal "0,caf\u00e9 na\u00efve\n", io.gets
            assert_equal text.lines[1..], io.readlines
            assert_empty io.readlines
          end
        end

        it "is read by CSV for #{description}, as an IO is" do
          rows = read_text { |io| CSV.new(io).to_a }

          assert_equal 5000, rows.size
          assert_equal ["4999", "caf\u00e9 na\u00efve"], rows.last
        end

        it "reads the end of the text like an IO for #{description}" do
          read_text do |io|
            assert_equal text, io.read
            assert_predicate io, :eof?

            buffer = +"data of an earlier read"

            assert_nil io.read(10)
            assert_nil io.read(10, buffer)
            assert_empty buffer
            assert_equal ["", Encoding::UTF_8], [io.read, io.read.encoding]
            assert_raises(EOFError) { io.readpartial(10) }
          end
        end
      end
    end

    it "reads like an IO for an uncompressed :enc stream" do
      read_back(:enc, {compress: false}, {}) do |io|
        assert_equal data[0, 10], io.readpartial(10)
        assert_equal data[10..], io.read
        assert_predicate io, :eof?
        assert_raises(EOFError) { io.readpartial(10) }
      end
    end
  end

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

      it "writes nothing for an empty string, like an IO, for the #{name.inspect} stream" do
        output = StringIO.new(+"".b)
        IOStreams.stream(output).stream(name, **writer_options).writer do |io|
          assert_equal 0, io.write("")
          assert_equal 3, io.write("", "id\n", "")
          assert_same io, io << ""
          assert_nil io.print("")
        end

        assert_equal "id\n", IOStreams.stream(StringIO.new(output.string)).stream(name, **reader_options).read
      end
    end

    it "writes nothing for an empty string, like an IO, for an uncompressed :enc stream" do
      output = StringIO.new(+"".b)
      IOStreams.stream(output).stream(:enc, compress: false).writer do |io|
        assert_equal 0, io.write("")
        io << "id\n" << ""
      end

      assert_equal "id\n", IOStreams.stream(StringIO.new(output.string)).stream(:enc).read
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
