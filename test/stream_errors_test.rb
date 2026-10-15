# frozen_string_literal: true

require_relative "test_helper"

# A stream that cannot read the data of a file raises an exception tagged with the kind of failure, such as
# `IOStreams::Errors::Corrupt`, whichever stream the file name names, since a path is configuration, so that code that
# rescues a corrupt `.gz` file still works when the file name changes to `.zip`, and whichever gem reads the format. The
# exception keeps the class that the gem raised, so that it can still be rescued by its class, as in v2.1.
class StreamErrorsTest < Minitest::Test
  # The class of the exception that each stream raises for data that is not in its format.
  NOT_THE_FORMAT = {
    bz2:  "Bzip2::FFI::Error::MagicDataError",
    enc:  "OpenSSL::Cipher::CipherError",
    gz:   "Zlib::GzipFile::Error",
    gzip: "Zlib::GzipFile::Error",
    # JRuby reads zip files with java.util.zip, so the zip stream raises its own exception there.
    zip:  defined?(JRuby) ? "IOStreams::Errors::StreamFailure" : "Zip::Error",
    # creek reads spreadsheets with rubyzip on every platform.
    xlsx: "Zip::Error",
    xlsm: "Zip::Error",
    zst:  "RuntimeError",
    # gpg reports why it failed in its status, which the PGP stream reads.
    pgp:  "IOStreams::Pgp::Failure",
    gpg:  "IOStreams::Pgp::Failure"
  }.freeze

  # Options needed to write and read each stream.
  STREAM_OPTIONS = {
    pgp: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}],
    gpg: [{recipient: "receiver@example.org"}, {passphrase: "receiver_passphrase"}]
  }.freeze

  describe "a stream that cannot read the data" do
    let(:data) { Array.new(5000) { |i| "#{i},#{'x' * 20}\n" }.join }

    # Returns [String] the data written through the named stream.
    def write(name, data)
      output = StringIO.new(+"".b)
      IOStreams.stream(output).stream(name, **STREAM_OPTIONS.fetch(name, [{}, {}]).first).write(data)
      output.string
    end

    # Returns [String] the data read through the named stream from the supplied bytes.
    def read(name, bytes)
      IOStreams.stream(StringIO.new(bytes)).stream(name, **STREAM_OPTIONS.fetch(name, [{}, {}]).last).read
    end

    it "lists every registered stream that reads" do
      readers = IOStreams.extensions.select { |_name, format| format.reader_class }.keys

      assert_equal readers.sort, NOT_THE_FORMAT.keys.sort
    end

    NOT_THE_FORMAT.each_pair do |name, class_name|
      it "raises Corrupt, keeping the exception's class, for data that is not #{name.inspect}" do
        error = assert_raises(IOStreams::Errors::Corrupt) { read(name, "Not #{name} data\n" * 100) }

        assert_instance_of Object.const_get(class_name), error
        assert_kind_of IOStreams::Errors::StreamError, error
        refute_kind_of IOStreams::Errors::StorageError, error
      end

      it "raises Corrupt for #{name.inspect} data that is cut short" do
        skip("zstd-ruby does not report a frame cut short") if name == :zst && !defined?(JRuby)

        written = write(name, data)

        assert_raises(IOStreams::Errors::Corrupt) { read(name, written.byteslice(0, written.bytesize / 2)) }
      end
    end

    it "raises Corrupt when reading a path, with the message of the gem" do
      Dir.mktmpdir do |dir|
        file_name = File.join(dir, "data.csv.gz")
        File.write(file_name, "Not gzip data\n")

        error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams.path(file_name).each(:line) { |line| line } }
        assert_instance_of Zlib::GzipFile::Error, error
        assert_equal "not in gzip format", error.message
      end
    end

    it "raises Corrupt for corrupt data within another stream" do
      corrupt = write(:gz, data)
      corrupt.setbyte(corrupt.bytesize / 2, corrupt.getbyte(corrupt.bytesize / 2) ^ 0x10)
      encrypted = write(:enc, corrupt)

      error = assert_raises(IOStreams::Errors::Corrupt) do
        IOStreams.stream(StringIO.new(encrypted)).stream(:gz).stream(:enc).read
      end
      assert_kind_of Zlib::Error, error
    end

    it "does not tag an exception that the block raises" do
      error = assert_raises(Zlib::GzipFile::Error) do
        IOStreams.stream(StringIO.new(write(:gz, data))).stream(:gz).reader { raise(Zlib::GzipFile::Error, "from the block") }
      end
      refute_kind_of IOStreams::Errors::StreamError, error

      error = assert_raises(OpenSSL::Cipher::CipherError) do
        IOStreams.stream(StringIO.new(write(:enc, data))).stream(:enc).reader { raise(OpenSSL::Cipher::CipherError, "from the block") }
      end
      refute_kind_of IOStreams::Errors::StreamError, error
    end
  end

  describe IOStreams::Errors::StreamError do
    it "keeps the kind of failure that an exception was tagged with first" do
      error = IOStreams::Errors::NotFound.tag(Errno::ENOENT.new("data.csv"), "/data/data.csv")

      assert_same error, IOStreams::Errors::Corrupt.tag(error, "/other.csv")
      refute_kind_of IOStreams::Errors::StreamError, error
      assert_equal "/data/data.csv", error.display_name
    end

    it "starts the message with the display name, unless it already includes it" do
      error = IOStreams::Errors::Corrupt.tag(Zlib::GzipFile::Error.new("not in gzip format"), "s3://bucket/data.csv.gz")

      assert_equal "s3://bucket/data.csv.gz: not in gzip format", error.message

      error = IOStreams::Errors::MissingEntry.tag(IOStreams::Errors::StreamFailure.new("/data/a.zip has none"), "/data/a.zip")

      assert_equal "/data/a.zip has none", error.message
    end

    it "keeps the message without a display name" do
      error = IOStreams::Errors::Corrupt.tag(RuntimeError.new("zstd decompress error: the data is empty"))

      assert_nil error.display_name
      assert_equal "zstd decompress error: the data is empty", error.message
    end

    it "is a family of its own, apart from the failures of the storage" do
      [IOStreams::Errors::Corrupt, IOStreams::Errors::MissingEntry].each do |kind|
        assert_includes kind.ancestors, IOStreams::Errors::StreamError
        refute_includes kind.ancestors, IOStreams::Errors::StorageError
      end
      [IOStreams::Errors::NotFound, IOStreams::Errors::PermissionDenied, IOStreams::Errors::Unavailable].each do |kind|
        refute_includes kind.ancestors, IOStreams::Errors::StreamError
      end
    end
  end
end
