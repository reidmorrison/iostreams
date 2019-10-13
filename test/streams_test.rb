require_relative 'test_helper'

class StreamsTest < Minitest::Test
  describe IOStreams::Streams do
    let(:file_name) { 'my/path/abc.bcd.xlsx.zip.gz.pgp' }
    let(:streams) { IOStreams::Streams.new(file_name) }

    describe '#option' do
      it 'adds one option' do
        streams.option(:pgp, passphrase: 'unlock-me')
        assert_equal({pgp: {passphrase: 'unlock-me'}}, streams.options)
      end

      it 'adds options in order' do
        streams.option(:pgp, passphrase: 'unlock-me')
        streams.option(:enc, compress: false)
        assert_equal({pgp: {passphrase: 'unlock-me'}, enc: {compress: false}}, streams.options)
      end

      it 'will not add an option if a stream was already set' do
        streams.stream(:pgp, passphrase: 'unlock-me')
        assert_raises ArgumentError do
          streams.option(:pgp, passphrase: 'unlock-me')
        end
      end

      it 'will not add an invalid option' do
        assert_raises ArgumentError do
          streams.option(:blah, value: 23)
        end
      end

      describe 'with no file_name' do
        let(:file_name) { nil }

        it 'prevents options being set' do
          assert_raises ArgumentError do
            streams.option(:pgp, passphrase: 'unlock-me')
          end
        end
      end
    end

    describe '#stream' do
      it 'adds one stream' do
        streams.stream(:pgp, passphrase: 'unlock-me')
        assert_equal({pgp: {passphrase: 'unlock-me'}}, streams.streams)
      end

      it 'adds streams in order' do
        streams.stream(:pgp, passphrase: 'unlock-me')
        streams.stream(:enc, compress: false)
        assert_equal({pgp: {passphrase: 'unlock-me'}, enc: {compress: false}}, streams.streams)
      end

      it 'will not add a stream if an option was already set' do
        streams.option(:pgp, passphrase: 'unlock-me')
        assert_raises ArgumentError do
          streams.stream(:pgp, passphrase: 'unlock-me')
        end
      end

      it 'will not add an invalid stream' do
        assert_raises ArgumentError do
          streams.stream(:blah, value: 23)
        end
      end
    end

    describe '#reader' do
      it 'directly calls block for an empty stream' do
        string_io = StringIO.new
        value     = nil
        streams.stream(:none)
        streams.reader(string_io) do |io|
          assert_equal io, string_io
          value = 32
        end
        assert_equal 32, value
      end

      it 'returns the reader' do
        string_io = StringIO.new
        streams.stream(:zip)
        streams.reader(string_io) do |io|
          assert io.is_a?(::Zip::InputStream), io
        end
      end

      it 'returns the last reader' do
        string_io = StringIO.new
        streams.stream(:encode)
        streams.stream(:zip)
        streams.reader(string_io) do |io|
          assert io.is_a?(IOStreams::Encode::Reader), io
        end
      end
    end

    describe '#writer' do
      it 'directly calls block for an empty stream' do
        string_io = StringIO.new
        value     = nil
        streams.stream(:none)
        streams.writer(string_io) do |io|
          assert_equal io, string_io
          value = 32
        end
        assert_equal 32, value
      end

      it 'returns the reader' do
        string_io = StringIO.new
        streams.stream(:zip)
        streams.writer(string_io) do |io|
          assert io.is_a?(::Zip::OutputStream), io
        end
      end

      it 'returns the last reader' do
        string_io = StringIO.new
        streams.stream(:encode)
        streams.stream(:zip)
        streams.writer(string_io) do |io|
          assert io.is_a?(IOStreams::Encode::Writer), io
        end
      end
    end

    # Internal methods

    describe '#class_for_stream' do
      it 'xlsx' do
        assert_equal IOStreams::Xlsx::Reader, streams.send(:class_for_stream, :reader, :xlsx)
      end

      it 'gzip' do
        assert_equal IOStreams::Gzip::Writer, streams.send(:class_for_stream, :writer, :gzip)
      end

      it 'unknown' do
        assert_raises ArgumentError do
          streams.send(:class_for_stream, :reader, :unknown)
        end
      end
    end

    describe '#parse_extensions' do
      it 'single stream' do
        streams = IOStreams::Streams.new('my/path/abc.xlsx')
        assert_equal %i[xlsx], streams.send(:parse_extensions)
      end

      it 'empty' do
        streams = IOStreams::Streams.new('my/path/abc.csv')
        assert_equal [], streams.send(:parse_extensions)
      end

      it 'handles multiple extensions' do
        assert_equal %i[xlsx zip gz pgp], streams.send(:parse_extensions)
      end

      describe 'case-insensitive' do
        let(:file_name) {'a.XlsX.GzIp'}

        it 'is case-insensitive' do
          assert_equal %i[xlsx gzip], streams.send(:parse_extensions)
        end
      end
    end

    describe '#build_streams' do
      it 'without options' do
        expected = {IOStreams::Xlsx::Reader => {}, IOStreams::Zip::Reader => {}, IOStreams::Gzip::Reader => {}, IOStreams::Pgp::Reader => {}}
        assert_equal(expected, streams.send(:build_streams, :reader))
      end

      it 'with encode option' do
        expected = {IOStreams::Xlsx::Reader => {}, IOStreams::Zip::Reader => {}, IOStreams::Gzip::Reader => {}, IOStreams::Pgp::Reader => {}}
        streams.option(:encode, encoding: 'BINARY')
        assert_equal(expected, streams.send(:build_streams, :reader))
      end

      it 'with streams' do
        streams.option(:pgp, passphrase: 'unlock-me')
        expected = {IOStreams::Xlsx::Reader => {}, IOStreams::Zip::Reader => {}, IOStreams::Gzip::Reader => {}, IOStreams::Pgp::Reader => {passphrase: 'unlock-me'}}
        assert_equal(expected, streams.send(:build_streams, :reader))
      end
    end

    describe '#execute' do
      it 'directly calls block for an empty stream' do
        string_io = StringIO.new
        value     = nil
        streams.send(:execute, {}, string_io) do |io|
          assert_equal io, string_io
          value = 32
        end
        assert_equal 32, value
      end

      it 'calls last block in one element stream' do
        streams_hash = {SimpleStream => {arg: 'first'}}
        string_io    = StringIO.new
        streams.send(:execute, streams_hash, string_io) { |io| io.write('last') }
        assert_equal 'first>last', string_io.string
      end

      it 'chains blocks in 2 element stream' do
        streams_hash = {SimpleStream => {arg: 'first'}, SimpleStream2 => {arg: 'second'}}
        puts "Hash has #{streams_hash.size}"
        string_io = StringIO.new
        streams.send(:execute, streams_hash, string_io) { |io| io.write('last') }
        assert_equal 'second>first>last', string_io.string
      end

      it 'chains blocks in 3 element stream' do
        streams_hash = {SimpleStream => {arg: 'first'}, SimpleStream2 => {arg: 'second'}, SimpleStream3 => {arg: 'third'}}
        string_io    = StringIO.new
        streams.send(:execute, streams_hash, string_io) { |io| io.write('last') }
        assert_equal 'third>second>first>last', string_io.string
      end
    end

    class SimpleStream
      def self.stream(io, **args)
        yield new(io, **args)
      end

      def initialize(io, arg:)
        @io  = io
        @arg = arg
      end

      def write(data)
        @io.write("#{@arg}>#{data}")
      end
    end

    class SimpleStream2 < SimpleStream
    end

    class SimpleStream3 < SimpleStream
    end
  end
end
