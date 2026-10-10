require_relative "test_helper"

class BuilderTest < Minitest::Test
  class SimpleStream
    def self.stream(io, **args)
      yield new(io, **args)
    end

    def self.open(file_name_or_io, **args, &)
      file_name_or_io.is_a?(String) ? file(file_name_or_io, **args, &) : stream(file_name_or_io, **args, &)
    end

    def initialize(io, arg:)
      @io  = io
      @arg = arg
    end

    def write(data)
      @io.write("#{@arg}>#{data}")
    end
  end

  IOStreams.register_extension(:simple, nil, SimpleStream)
  IOStreams.register_extension(:simple2, nil, SimpleStream)
  IOStreams.register_extension(:simple3, nil, SimpleStream)

  describe IOStreams::Builder do
    let(:file_name) { "my/path/abc.bcd.xlsx.zip.gz.pgp" }
    let(:streams) { IOStreams::Builder.new(file_name) }

    describe "#option" do
      it "adds one option" do
        streams.option(:pgp, passphrase: "unlock-me")

        assert_equal({pgp: {passphrase: "unlock-me"}}, streams.options)
      end

      it "adds options in order" do
        streams.option(:pgp, passphrase: "unlock-me")
        streams.option(:enc, compress: false)

        assert_equal({pgp: {passphrase: "unlock-me"}, enc: {compress: false}}, streams.options)
      end

      it "will not add an option if a stream was already set" do
        streams.stream(:pgp, passphrase: "unlock-me")
        error = assert_raises ArgumentError do
          streams.option(:pgp, passphrase: "unlock-me")
        end
        assert_equal "Cannot call both #option and #stream on the same streams instance", error.message
      end

      it "will not add an invalid option" do
        assert_raises ArgumentError do
          streams.option(:blah, value: 23)
        end
      end

      describe "with no file_name" do
        let(:file_name) { nil }

        it "prevents options being set" do
          error = assert_raises ArgumentError do
            streams.option(:pgp, passphrase: "unlock-me")
          end
          assert_equal "Cannot call #option unless the `file_name` was already set", error.message
        end
      end
    end

    describe "#stream" do
      it "adds one stream" do
        streams.stream(:pgp, passphrase: "unlock-me")

        assert_equal({pgp: {passphrase: "unlock-me"}}, streams.streams)
      end

      it "adds streams in order" do
        streams.stream(:pgp, passphrase: "unlock-me")
        streams.stream(:enc, compress: false)

        assert_equal({pgp: {passphrase: "unlock-me"}, enc: {compress: false}}, streams.streams)
      end

      it "will not add a stream if an option was already set" do
        streams.option(:pgp, passphrase: "unlock-me")
        error = assert_raises ArgumentError do
          streams.stream(:pgp, passphrase: "unlock-me")
        end
        assert_equal "Cannot call both #option and #stream on the same streams instance", error.message
      end

      it "will not add an invalid stream" do
        assert_raises ArgumentError do
          streams.stream(:blah, value: 23)
        end
      end
    end

    describe "#reader" do
      let :gzip_string do
        io_string = StringIO.new("".b)
        IOStreams::Gzip::Writer.stream(io_string) do |io|
          io.write("Hello World")
        end
        io_string.string
      end

      it "directly calls block for an empty stream" do
        string_io = StringIO.new
        value     = nil
        streams.stream(:none)
        streams.reader(string_io) do |io|
          assert_equal io, string_io
          value = 32
        end

        assert_equal 32, value
      end

      it "returns the reader" do
        string_io = StringIO.new(gzip_string)
        streams.stream(:gz)

        streams.reader(string_io) do |io|
          assert_kind_of IOStreams::Gzip::Reader::Members, io, io
        end
      end

      it "returns the last reader" do
        string_io = StringIO.new(gzip_string)
        streams.stream(:encode)
        streams.stream(:gz)

        streams.reader(string_io) do |io|
          assert_kind_of IOStreams::Encode::Reader, io, io
        end
      end
    end

    describe "#writer" do
      it "directly calls block for an empty stream" do
        string_io = StringIO.new
        value     = nil
        streams.stream(:none)
        streams.writer(string_io) do |io|
          assert_equal io, string_io
          value = 32
        end

        assert_equal 32, value
      end

      it "returns the reader" do
        string_io = StringIO.new
        streams.stream(:zip)

        streams.writer(string_io) do |io|
          assert_kind_of ZipKit::Streamer::Writable, io, io
        end
      end

      it "returns the last reader" do
        string_io = StringIO.new
        streams.stream(:encode)
        streams.stream(:zip)

        streams.writer(string_io) do |io|
          assert_kind_of IOStreams::Encode::Writer, io, io
        end
      end
    end

    describe ".reserved_keyword?" do
      it "is true for the built-in encode stream and for none" do
        assert IOStreams::Builder.reserved_keyword?(:encode)
        assert IOStreams::Builder.reserved_keyword?(:none)
      end

      it "is false for a stream registered for a file name extension" do
        refute IOStreams::Builder.reserved_keyword?(:gz)
        refute IOStreams::Builder.reserved_keyword?(:simple)
      end
    end

    # Internal methods

    describe "#raw" do
      it "applies no streams, although the file name implies them" do
        streams.raw

        assert_empty(streams.pipeline)
        assert_predicate streams, :raw?
      end

      it "clears the streams, options and encoding already set" do
        streams.option(:pgp, passphrase: "unlock-me").encoding("BINARY").raw

        assert_empty(streams.pipeline)
        assert_nil streams.setting(:pgp)
        assert_nil streams.setting(:encode)
      end

      it "clears the streams set with #stream" do
        streams.stream(:gz).raw

        assert_empty(streams.pipeline)
      end

      it "is not raw by default" do
        refute_predicate streams, :raw?
      end

      it "raises when a stream, option or encoding is set afterwards" do
        streams.raw

        [
          -> { streams.stream(:gz) },
          -> { streams.stream(:none) },
          -> { streams.option(:gz) },
          -> { streams.encoding("UTF-8") },
          -> { streams.option(:encode, encoding: "UTF-8") }
        ].each do |call|
          error = assert_raises(ArgumentError) { call.call }

          assert_includes error.message, "after #raw, which reads and writes the data as it is stored"
        end
      end

      it "is kept by a copy" do
        assert_predicate streams.raw.dup, :raw?
      end

      it "reads text as it is stored, without a default encoding" do
        streams.raw
        copy = streams.with_default_encoding("US-ASCII:UTF-8")

        assert_empty(copy.pipeline)
        assert_equal "caf\xE9".b, copy.text("caf\xE9".b)
        copy.text_reader(StringIO.new("caf\xE9".b)) { |io| assert_equal "caf\xE9".b, io.read }
      end
    end

    describe "#stream_format" do
      it "xlsx" do
        assert_equal IOStreams::Xlsx, streams.send(:stream_format, :xlsx)
      end

      it "gzip" do
        assert_equal IOStreams::Gzip, streams.send(:stream_format, :gzip)
      end

      it "encode, which is built in" do
        assert_equal IOStreams::Encode, streams.send(:stream_format, :encode)
      end

      it "unknown" do
        assert_raises ArgumentError do
          streams.send(:stream_format, :unknown)
        end
      end
    end

    describe "#parse_extensions" do
      it "single stream" do
        streams = IOStreams::Builder.new("my/path/abc.xlsx")

        assert_equal %i[xlsx], streams.send(:parse_extensions)
      end

      it "empty" do
        streams = IOStreams::Builder.new("my/path/abc.csv")

        assert_equal [], streams.send(:parse_extensions)
      end

      it "handles multiple extensions" do
        assert_equal %i[xlsx zip gz pgp], streams.send(:parse_extensions)
      end

      it "ignores the name of the file" do
        assert_equal [], IOStreams::Builder.new("my/path/gz").send(:parse_extensions)
        assert_equal [], IOStreams::Builder.new("my/path.zip/abc").send(:parse_extensions)
        assert_equal %i[gz], IOStreams::Builder.new("my/path/.zip.gz").send(:parse_extensions)
      end

      describe "case-insensitive" do
        let(:file_name) { "a.XlsX.GzIp" }

        it "is case-insensitive" do
          assert_equal %i[xlsx gzip], streams.send(:parse_extensions)
        end
      end

      it "ignores a stream that file names do not name" do
        assert_equal [], IOStreams::Builder.new("my/path/notes.encode").send(:parse_extensions)
        assert_equal %i[gz], IOStreams::Builder.new("my/path/notes.encode.gz").send(:parse_extensions)
      end
    end

    describe "#pipeline" do
      it "with stream and file name" do
        expected = {enc: {compress: false}}
        streams.stream(:enc, compress: false)

        assert_equal expected, streams.pipeline
      end

      it "no file name, streams, or options" do
        expected = {}
        streams  = IOStreams::Builder.new

        assert_equal expected, streams.pipeline
      end

      it "file name without options" do
        expected = {xlsx: {}, zip: {}, gz: {}, pgp: {}}

        assert_equal expected, streams.pipeline
      end

      it "file name with encode option" do
        expected = {encode: {encoding: "BINARY"}, xlsx: {}, zip: {}, gz: {}, pgp: {}}
        streams.option(:encode, encoding: "BINARY")

        assert_equal expected, streams.pipeline
      end

      it "applies the encode option before the file name's streams, whatever order the options are set in" do
        streams.option(:pgp, passphrase: "unlock-me").option(:encode, encoding: "BINARY")

        expected = [[:encode, {encoding: "BINARY"}], [:xlsx, {}], [:zip, {}], [:gz, {}], [:pgp, {passphrase: "unlock-me"}]]

        assert_equal expected, streams.pipeline.to_a
      end

      it "puts the encode stream first, whatever order the streams are set in" do
        streams.stream(:gz).stream(:encode, encoding: "UTF-8").stream(:pgp)

        assert_equal [[:encode, {encoding: "UTF-8"}], [:gz, {}], [:pgp, {}]], streams.pipeline.to_a
      end

      it "does not apply the option for a stream that the file name does not include" do
        streams.option(:bz2, block_size: 9)

        assert_equal({xlsx: {}, zip: {}, gz: {}, pgp: {}}, streams.pipeline)
      end

      it "ignores the option for a stream that is no longer registered" do
        IOStreams.register_extension(:gone_test, nil, SimpleStream)
        streams.option(:gone_test, arg: "gone")
        IOStreams.deregister_extension(:gone_test)

        assert_equal({xlsx: {}, zip: {}, gz: {}, pgp: {}}, streams.pipeline)
      end

      it "file name with option" do
        expected = {xlsx: {}, zip: {}, gz: {}, pgp: {passphrase: "unlock-me"}}
        streams.option(:pgp, passphrase: "unlock-me")

        assert_equal expected, streams.pipeline
      end
    end

    describe "#encoding" do
      it "applies the encode stream before the streams from the file name" do
        streams.encoding("Windows-1252:UTF-8")

        expected = [[:encode, {encoding: "Windows-1252:UTF-8"}], [:xlsx, {}], [:zip, {}], [:gz, {}], [:pgp, {}]]

        assert_equal expected, streams.pipeline.to_a
      end

      it "merges the encoding with the other options and with those already set" do
        streams.encoding("UTF-8").encoding(replace: "?").encoding(cleaner: :printable)

        assert_equal({encoding: "UTF-8", replace: "?", cleaner: :printable}, streams.setting(:encode))
      end

      it "can be combined with streams" do
        streams.stream(:gz).encoding("BINARY")

        assert_equal({encode: {encoding: "BINARY"}, gz: {}}, streams.pipeline)
      end

      it "can be combined with options" do
        streams.option(:pgp, passphrase: "unlock-me").encoding("BINARY")

        assert_equal({encoding: "BINARY"}, streams.pipeline[:encode])
        assert_equal({passphrase: "unlock-me"}, streams.pipeline[:pgp])
      end

      it "needs no file name" do
        assert_equal({encode: {encoding: "BINARY"}}, IOStreams::Builder.new.encoding("BINARY").pipeline)
      end

      it "is set by the deprecated option(:encode)" do
        streams.option(:encode, encoding: "BINARY").encoding(replace: "")

        assert_equal({encoding: "BINARY", replace: ""}, streams.setting(:encode))
      end

      it "is set by the deprecated option(:encode) after #stream" do
        streams.stream(:gz).option(:encode, encoding: "BINARY")

        assert_equal({encode: {encoding: "BINARY"}, gz: {}}, streams.pipeline)
      end

      it "is set by the deprecated stream(:encode), which still stops the streams from the file name" do
        streams.stream(:encode, encoding: "BINARY")

        assert_equal({encode: {encoding: "BINARY"}}, streams.pipeline)
      end

      it "is cleared by stream(:none)" do
        streams.encoding("BINARY").stream(:none)

        assert_empty(streams.pipeline)
        assert_nil streams.setting(:encode)
      end

      it "is removed from the pipeline" do
        streams.encoding("BINARY")

        assert_equal({encoding: "BINARY"}, streams.remove_from_pipeline(:encode))
        assert_equal({xlsx: {}, zip: {}, gz: {}, pgp: {}}, streams.pipeline)
      end

      it "is not shared with a copy" do
        streams.encoding("BINARY")
        copy = streams.dup
        copy.encoding(replace: "")

        assert_equal({encoding: "BINARY"}, streams.setting(:encode))
      end

      it "raises without an encoding or options" do
        error = assert_raises(ArgumentError) { streams.encoding }

        assert_equal "Supply the encoding, or options for the encode stream", error.message
      end

      it "raises when the encoding is supplied twice" do
        error = assert_raises(ArgumentError) { streams.encoding("UTF-8", encoding: "BINARY") }

        assert_equal "Supply the encoding as an argument or as `encoding:`, not both", error.message
      end

      it "raises for an option that the encode stream does not take" do
        assert_raises(ArgumentError) { streams.encoding("UTF-8", replacement: "?") }
        assert_nil streams.setting(:encode)
      end
    end

    describe "#redacted" do
      it "replaces the values of sensitive options in a copy" do
        streams.option(:pgp, passphrase: "TOP-SECRET", verify_first: true)
        copy = streams.redacted

        assert_equal({pgp: {passphrase: "[FILTERED]", verify_first: true}}, copy.options)
        assert_equal({passphrase: "[FILTERED]", verify_first: true}, copy.pipeline[:pgp])
        assert_equal({pgp: {passphrase: "TOP-SECRET", verify_first: true}}, streams.options)
      end

      it "replaces the values of the streams" do
        streams.stream(:pgp, signer_passphrase: "TOP-SECRET", recipient: "a@b.org")

        assert_equal({pgp: {signer_passphrase: "[FILTERED]", recipient: "a@b.org"}}, streams.redacted.streams)
      end

      it "replaces every value of a stream that is no longer registered" do
        IOStreams.register_extension(:gone_test, nil, SimpleStream)
        streams.stream(:gone_test, arg: "TOP-SECRET")
        IOStreams.deregister_extension(:gone_test)

        assert_equal({gone_test: {arg: "[FILTERED]"}}, streams.redacted.streams)
      end
    end

    describe "#inspect" do
      it "does not display the values of sensitive options" do
        streams.option(:pgp, passphrase: "TOP-SECRET")
        str = streams.inspect

        refute_includes str, "TOP-SECRET"
        assert_includes str, file_name
      end
    end

    describe "#remove_from_pipeline" do
      let(:file_name) { "my/path/abc.bz2.pgp" }
      it "removes a named stream from the pipeline" do
        assert_equal({bz2: {}, pgp: {}}, streams.pipeline)
        streams.remove_from_pipeline(:bz2)

        assert_equal({pgp: {}}, streams.pipeline)
      end
      it "removes a named stream from the pipeline with options" do
        streams.option(:pgp, passphrase: "unlock-me")

        assert_equal({bz2: {}, pgp: {passphrase: "unlock-me"}}, streams.pipeline)
        streams.remove_from_pipeline(:bz2)

        assert_equal({pgp: {passphrase: "unlock-me"}}, streams.pipeline)
      end
    end

    describe "#execute" do
      it "directly calls block for an empty stream" do
        string_io = StringIO.new
        value     = nil
        streams.send(:execute, :writer, {}, string_io) do |io|
          assert_equal io, string_io
          value = 32
        end

        assert_equal 32, value
      end

      it "calls last block in one element stream" do
        pipeline  = {simple: {arg: "first"}}
        string_io = StringIO.new
        streams.send(:execute, :writer, pipeline, string_io) { |io| io.write("last") }

        assert_equal "first>last", string_io.string
      end

      it "chains blocks in 2 element stream" do
        pipeline  = {simple: {arg: "first"}, simple2: {arg: "second"}}
        string_io = StringIO.new
        streams.send(:execute, :writer, pipeline, string_io) { |io| io.write("last") }

        assert_equal "second>first>last", string_io.string
      end

      it "chains blocks in 3 element stream" do
        pipeline  = {simple: {arg: "first"}, simple2: {arg: "second"}, simple3: {arg: "third"}}
        string_io = StringIO.new
        streams.send(:execute, :writer, pipeline, string_io) { |io| io.write("last") }

        assert_equal "third>second>first>last", string_io.string
      end
    end
  end
end
