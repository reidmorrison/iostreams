require_relative "test_helper"

class PgpReaderTest < Minitest::Test
  describe IOStreams::Pgp::Reader do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :decrypted do
      file_name = File.join(File.dirname(__FILE__), "files", "text.txt")
      File.read(file_name)
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "reads encrypted file" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase", &:read)
        assert_equal decrypted, result
      end

      it "fails with bad passphrase" do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "BAD", &:read)
        end
      end

      it "streams input" do
        io_string = StringIO.new("".b)
        IOStreams::Pgp::Writer.stream(io_string, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
          io.write(decrypted)
        end

        io     = StringIO.new(io_string.string)
        result = IOStreams::Pgp::Reader.stream(io, passphrase: "receiver_passphrase", &:read)
        assert_equal decrypted, result
      end
    end
  end
end
