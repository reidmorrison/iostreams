require_relative "test_helper"

class SymmetricEncryptionWriterTest < Minitest::Test
  describe IOStreams::SymmetricEncryption::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decrypted do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "writes an encrypted file" do
        result =
          IOStreams::SymmetricEncryption::Writer.file(file_name) do |io|
            io.write(decrypted)
            53_534
          end

        assert_equal 53_534, result

        refute_equal decrypted, File.read(file_name, mode: "rb")
        assert_equal decrypted, ::SymmetricEncryption::Reader.open(file_name, &:read)
      end
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
      end

      it "writes an uncompressed encrypted stream" do
        io_string = StringIO.new("".b)
        IOStreams::SymmetricEncryption::Writer.stream(io_string, compress: false) do |io|
          io.write(decrypted)
        end

        io = StringIO.new(io_string.string)

        assert_equal decrypted, ::SymmetricEncryption::Reader.open(io, &:read)
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

        refute_equal decrypted, IOStreams.path(path.to_s).stream(:none).read
        assert_equal decrypted, IOStreams.path(path.to_s).read
      end
    end
  end
end
