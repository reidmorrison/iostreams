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

      # We cannot reliably generate an MDC-less file across GnuPG versions (modern GnuPG
      # mandates MDC), so this only verifies that ignore_mdc_error is accepted and remains
      # harmless for a normal encrypted file. The flag's real effect is on legacy files.
      it "decrypts with ignore_mdc_error enabled" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase", ignore_mdc_error: true, &:read)

        assert_equal decrypted, result
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

    describe "verify_first" do
      # A signed file whose contents were changed after signing.
      # Compression is disabled so that the signed text is stored as is and can be changed.
      let :tampered_file_name do
        IOStreams::Pgp::Writer.file(temp_file.path, encrypt: false, signer: "sender@example.org",
                                                    signer_passphrase: "sender_passphrase", compress_level: 0) do |io|
          io.write("Pay Jack 100")
        end
        data = File.binread(temp_file.path)
        File.binwrite(temp_file.path, data.sub("Pay Jack 100", "Pay Jack 900"))
        temp_file.path
      end

      it "reads an encrypted file" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase", verify_first: true, &:read)

        assert_equal decrypted, result
      end

      it "returns the value from the block" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") { |io| io.write(decrypted) }

        result = IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase", verify_first: true) { |_io| 257 }

        assert_equal 257, result
      end

      it "by default passes contents to the block before the signature is checked" do
        received = nil
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Reader.file(tampered_file_name) { |io| received = io.read }
        end

        assert_equal "Pay Jack 900", received
      end

      it "does not pass contents to the block when the signature is bad" do
        called = false
        error  = assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Reader.file(tampered_file_name, verify_first: true) { |_io| called = true }
        end

        assert_match(/BAD signature/, error.message)
        refute called
      end

      it "does not pass contents to the block when decryption fails" do
        File.write(temp_file.path, "Not a PGP file")
        called = false
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase", verify_first: true) { |_io| called = true }
        end

        refute called
      end

      it "is supported as a stream option" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") { |io| io.write(decrypted) }
        path = IOStreams.path(temp_file.path).stream(:pgp, passphrase: "receiver_passphrase", verify_first: true)

        assert_equal decrypted, path.read
      end
    end
  end
end
