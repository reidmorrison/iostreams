# frozen_string_literal: true

require_relative "test_helper"

class SymmetricEncryptionWriterTest < Minitest::Test
  describe IOStreams::SymmetricEncryption::Writer do
    let :decrypted do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    describe ".stream" do
      it "writes an encrypted stream" do
        io_string = StringIO.new("".b)
        IOStreams::SymmetricEncryption::Writer.stream(io_string) do |io|
          io.write(decrypted)
        end

        refute_equal decrypted, io_string.string
        io = StringIO.new(io_string.string)

        assert_equal decrypted, ::SymmetricEncryption::Reader.open(io, &:read)
        assert_equal [true, true], header_and_compression(io_string.string)
      end

      it "raises for an option that it does not take" do
        error = assert_raises(ArgumentError) { IOStreams::SymmetricEncryption::Writer.stream(StringIO.new, bogus: 1) { |io| io.write(decrypted) } }
        assert_equal "unknown keyword: :bogus", error.message
      end

      it "writes an uncompressed encrypted stream" do
        io_string = StringIO.new("".b)
        IOStreams::SymmetricEncryption::Writer.stream(io_string, compress: false) do |io|
          io.write(decrypted)
        end

        io = StringIO.new(io_string.string)

        assert_equal decrypted, ::SymmetricEncryption::Reader.open(io, &:read)
        assert_equal [true, false], header_and_compression(io_string.string)
      end

      # Returns [Array<true|false>] whether the encrypted data has a header, and whether the header says that the data
      # is compressed.
      def header_and_compression(encrypted)
        reader = ::SymmetricEncryption::Reader.new(StringIO.new(encrypted))
        [reader.header_present?, reader.compressed?]
      end
    end

    describe ".enc extension" do
      let :path do
        IOStreams.join("symmetric_encryption_writer_test.enc")
      end

      after do
        path.delete
      end

      it "encrypts when writing to a path with a .enc extension" do
        path.write(decrypted)

        refute_equal decrypted, IOStreams.path(path.to_s).raw.read
        assert_equal decrypted, IOStreams.path(path.to_s).read
      end
    end

    describe ".check" do
      it "accepts the options of the configured cipher" do
        assert_nil IOStreams::SymmetricEncryption::Writer.check
        assert_nil IOStreams::SymmetricEncryption::Writer.check(compress: false, header: false)
      end

      it "raises what the writer of the gem raises" do
        assert_raises(::SymmetricEncryption::CipherError) { IOStreams::SymmetricEncryption::Writer.check(version: 99) }
        assert_raises(ArgumentError) { IOStreams::SymmetricEncryption::Writer.check(random_iv: false) }
      end

      it "keeps an existing local file" do
        Dir.mktmpdir do |dir|
          file_name = File.join(dir, "data.csv.enc")
          File.write(file_name, "precious")

          assert_raises(::SymmetricEncryption::CipherError) { IOStreams.path(file_name).option(:enc, version: 99).write(decrypted) }
          assert_equal "precious", File.read(file_name)
        end
      end
    end
  end
end
