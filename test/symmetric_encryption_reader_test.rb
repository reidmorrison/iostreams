# frozen_string_literal: true

require_relative "test_helper"

class SymmetricEncryptionReaderTest < Minitest::Test
  describe IOStreams::SymmetricEncryption::Reader do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decrypted do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    before do
      ::SymmetricEncryption::Writer.open(file_name) { |io| io.write(decrypted) }
    end

    after do
      temp_file.delete
    end

    describe ".stream" do
      it "reads an encrypted stream" do
        result =
          File.open(file_name, "rb") do |file|
            IOStreams::SymmetricEncryption::Reader.stream(file, &:read)
          end

        assert_equal decrypted, result
      end
    end

    describe "an option" do
      it "raises for an option that it does not take" do
        error = assert_raises(ArgumentError) do
          File.open(file_name, "rb") { |file| IOStreams::SymmetricEncryption::Reader.stream(file, bogus: 1, &:read) }
        end
        assert_equal "unknown keyword: :bogus", error.message
      end
    end

    describe "the kind of failure" do
      it "is MissingKey for data encrypted with the version of a cipher that is not configured" do
        primary = ::SymmetricEncryption.cipher
        ::SymmetricEncryption.cipher = ::SymmetricEncryption::Cipher.new(
          cipher_name: "aes-128-cbc", key: "ABCDEF1234567890", iv: "1234567890ABCDEF", version: 7
        )
        begin
          ::SymmetricEncryption::Writer.open(file_name) { |io| io.write(decrypted) }
        ensure
          ::SymmetricEncryption.cipher = primary
        end

        error = assert_raises(::SymmetricEncryption::CipherError) do
          IOStreams::SymmetricEncryption::Reader.file(file_name, &:read)
        end
        assert_kind_of IOStreams::Errors::MissingKey, error
        assert_includes error.message, "version:7"
      end

      it "is Corrupt for empty data, which the writer never writes" do
        File.write(file_name, "")

        error = assert_raises(IOStreams::Errors::Corrupt) { IOStreams::SymmetricEncryption::Reader.file(file_name, &:read) }
        assert_instance_of IOStreams::Errors::StreamFailure, error
        assert_equal "The encrypted data is empty", error.message
      end

      it "reads encrypted data that holds no data as empty" do
        [{}, {compress: false}].each do |options|
          output = StringIO.new(+"".b)
          IOStreams.stream(output).stream(:enc, **options).write("")

          assert_equal "", IOStreams::SymmetricEncryption::Reader.stream(StringIO.new(output.string), &:read)
        end
      end

      it "is Corrupt for data that is not encrypted" do
        File.write(file_name, "Not encrypted data\n" * 10)

        error = assert_raises(OpenSSL::Cipher::CipherError) { IOStreams::SymmetricEncryption::Reader.file(file_name, &:read) }
        assert_kind_of IOStreams::Errors::Corrupt, error
      end
    end

    describe ".file" do
      it "reads an encrypted file" do
        result = IOStreams::SymmetricEncryption::Reader.file(file_name, &:read)

        assert_equal decrypted, result
      end
    end

    describe ".open" do
      it "reads an encrypted file by name" do
        result = IOStreams::SymmetricEncryption::Reader.open(file_name, &:read)

        assert_equal decrypted, result
      end
    end

    describe "the :stream mode" do
      # Like `Zlib::GzipReader`, which returned the data of a compressed file in the default external encoding.
      def read_with_external_encoding(data, encoding, **options)
        original = Encoding.default_external
        Encoding.default_external = encoding
        output = StringIO.new(+"".b)
        IOStreams.stream(output).stream(:enc, **options).write(data)
        IOStreams.stream(StringIO.new(output.string)).stream(:enc).reader { |io| [io.read(3), io.read] }
      ensure
        Encoding.default_external = original
      end

      it "returns bytes from compressed data, with or without a length, whatever the default external encoding" do
        start, rest = read_with_external_encoding("José\n", "Windows-1252")

        assert_equal "Jos".b, start
        assert_equal Encoding::BINARY, start.encoding
        assert_equal "\xC3\xA9\n".b, rest
        assert_equal Encoding::BINARY, rest.encoding
      end

      it "returns bytes from data that is not compressed" do
        start, rest = read_with_external_encoding("José\n", "Windows-1252", compress: false)

        assert_equal [Encoding::BINARY, Encoding::BINARY], [start.encoding, rest.encoding]
        assert_equal "José\n".b, start + rest
      end
    end

    describe ".enc extension" do
      let :path do
        IOStreams.join("symmetric_encryption_reader_test.enc")
      end

      after do
        path.delete
      end

      it "decrypts when reading from a path with a .enc extension" do
        path.write(decrypted)

        assert_equal decrypted, IOStreams.join("symmetric_encryption_reader_test.enc").read
      end

      it "reads an encrypted file a line at a time" do
        path.write("first line\nsecond line\n")

        lines = []
        # IOStreams streams expose #each, not #map, so this is not a map-into-array.
        IOStreams.join("symmetric_encryption_reader_test.enc").each { |line| lines << line } # rubocop:disable Style/MapIntoArray

        assert_equal ["first line", "second line"], lines
      end
    end
  end
end
