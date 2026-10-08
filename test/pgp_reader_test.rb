require_relative "test_helper"
require "timeout"

class PgpReaderTest < Minitest::Test
  # A stream that returns the start of the data, and then raises, like compressed data that is corrupt.
  class CorruptInput
    def initialize(data)
      @data = data
    end

    def read(length = nil, outbuf = nil)
      raise(Zlib::DataError, "invalid compressed data") if @read

      @read = true
      data  = @data.byteslice(0, [length || 100, 100].min)
      outbuf ? outbuf.replace(data) : data
    end
  end

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

      describe "when the block does not read the whole file" do
        let :large_data do
          "line of decrypted data\n" * 100_000
        end

        before do
          IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") { |io| io.write(large_data) }
        end

        it "returns the result of the block" do
          result = Timeout.timeout(30) do
            IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase") { |io| io.read(10) }
          end

          assert_equal large_data[0, 10], result
        end

        it "returns the first line" do
          result = Timeout.timeout(30) do
            IOStreams.path(temp_file.path).stream(:pgp, passphrase: "receiver_passphrase").reader(:line, &:readline)
          end

          assert_equal "line of decrypted data", result
        end
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

    describe ".stream" do
      let :large_data do
        # Random bytes, which gpg cannot compress, so that the encrypted data fills the pipes to and from gpg.
        Random.new(42).bytes(2_000_000)
      end

      def encrypt(data)
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org", signer: "sender@example.org",
                                                    signer_passphrase: "sender_passphrase") { |io| io.write(data) }
        File.binread(temp_file.path)
      end

      it "decrypts a stream that is not a local file through gpg's stdin, without a temp file" do
        input  = StringIO.new(encrypt(decrypted))
        result = nil
        temps  = temp_files_created do
          result = IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase", &:read)
        end

        assert_equal decrypted, result
        assert_empty temps
        refute_predicate input, :closed?
      end

      it "returns the result of the block when it does not read the whole stream" do
        input  = StringIO.new(encrypt(large_data))
        result = Timeout.timeout(30) do
          IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase") { |io| io.read(10) }
        end

        assert_equal large_data.byteslice(0, 10), result
      end

      it "stops reading the stream when the block raises" do
        input = StringIO.new(encrypt(large_data))
        error = Timeout.timeout(30) do
          assert_raises(ArgumentError) do
            IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase") do |io|
              io.read(10)
              raise(ArgumentError, "from the block")
            end
          end
        end

        assert_equal "from the block", error.message
        refute_predicate input, :closed?
      end

      it "raises the failure to read the stream, rather than the failure of gpg that it causes" do
        input = CorruptInput.new(encrypt(decrypted))
        error = Timeout.timeout(30) do
          assert_raises(Zlib::DataError) { IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase", &:read) }
        end

        assert_equal "invalid compressed data", error.message
      end

      it "raises when gpg cannot decrypt the stream" do
        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Reader.stream(StringIO.new("Not a PGP file"), passphrase: "receiver_passphrase", &:read)
        end

        assert_match(/\AGPG Failed to decrypt stream: /, error.message)
      end

      it "checks who signed the stream" do
        input = StringIO.new(encrypt(decrypted))
        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase", signer: "receiver2@example.org", &:read)
        end

        assert_equal "PGP stream was not signed by receiver2@example.org", error.message
      end

      it "verifies the stream before passing it to the block with verify_first" do
        input  = StringIO.new(encrypt(decrypted))
        result = IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase", signer: "sender@example.org",
                                                      verify_first: true, &:read)

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

    describe "signer" do
      def write(**signing)
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org", **signing) { |io| io.write(decrypted) }
        temp_file.path
      end

      def read(file_name, **options, &block)
        IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", **options, &block || :read)
      end

      let :signed_by_sender do
        write(signer: "sender@example.org", signer_passphrase: "sender_passphrase")
      end

      it "reads a file signed by the signer" do
        assert_equal decrypted, read(signed_by_sender, signer: "sender@example.org")
        assert_equal decrypted, read(signed_by_sender, signer: "sender@example.org", verify_first: true)
      end

      it "identifies the signer by fingerprint" do
        fingerprint = IOStreams::Pgp.primary_fingerprints("sender@example.org").first

        assert_equal decrypted, read(signed_by_sender, signer: fingerprint)
      end

      it "raises after the block for a file signed by someone else" do
        file_name = write(signer: "receiver2@example.org", signer_passphrase: "receiver2_passphrase")
        received  = nil
        error     = assert_raises(IOStreams::Pgp::Failure) do
          read(file_name, signer: "sender@example.org") { |io| received = io.read }
        end

        assert_match(/\APGP file was not signed by sender@example.org: /, error.message)
        assert_equal decrypted, received
      end

      it "does not pass contents to the block for an unsigned file with verify_first" do
        file_name = write
        called    = false
        assert_raises(IOStreams::Pgp::Failure) do
          read(file_name, signer: "sender@example.org", verify_first: true) { |_io| called = true }
        end

        refute called
      end

      it "only matches the exact email address" do
        error = assert_raises(IOStreams::Pgp::Failure) { read(signed_by_sender, signer: "der@example.org") }

        assert_equal "No PGP key found for the signer: der@example.org", error.message
      end

      it "raises before reading when there is no key for the signer" do
        called = false
        assert_raises(IOStreams::Pgp::Failure) do
          read(signed_by_sender, signer: "nobody@example.org") { |_io| called = true }
        end

        refute called
      end

      it "raises when gpg does not trust the signer's key" do
        untrusted_pgp_key
        file_name = write(signer: "untrusted@example.org", signer_passphrase: "untrusted_passphrase")

        error = assert_raises(IOStreams::Pgp::Failure) { read(file_name, signer: "untrusted@example.org") }
        assert_match(/\APGP file was signed by untrusted@example.org, but gpg does not trust the key/, error.message)
      end

      it "is supported as a stream option" do
        path = IOStreams.path(signed_by_sender).stream(:pgp, passphrase: "receiver_passphrase", signer: "sender@example.org")

        assert_equal decrypted, path.read
      end

      describe "import_and_trust_key" do
        let :signed_by_untrusted do
          key = untrusted_pgp_key
          write(signer: "untrusted@example.org", signer_passphrase: "untrusted_passphrase")
          key
        end

        it "reads a file signed by the imported key, which gpg need not trust" do
          key = signed_by_untrusted

          assert_equal decrypted, read(temp_file.path, import_and_trust_key: key)
          assert_equal decrypted, read(temp_file.path, import_and_trust_key: [key], verify_first: true)
        end

        it "raises for a file signed by another key" do
          key   = untrusted_pgp_key
          error = assert_raises(IOStreams::Pgp::Failure) { read(signed_by_sender, import_and_trust_key: key) }

          assert_match(/\APGP file was not signed by the imported key: /, error.message)
        end

        it "raises for an unsigned file" do
          key = untrusted_pgp_key
          assert_raises(IOStreams::Pgp::Failure) { read(write, import_and_trust_key: key, verify_first: true) }
        end

        it "accepts a file signed by either the signer or the imported key" do
          key = untrusted_pgp_key

          assert_equal decrypted, read(signed_by_sender, signer: "sender@example.org", import_and_trust_key: key)
        end

        it "names both when signed by neither" do
          key       = untrusted_pgp_key
          file_name = write(signer: "receiver2@example.org", signer_passphrase: "receiver2_passphrase")
          error     = assert_raises(IOStreams::Pgp::Failure) do
            read(file_name, signer: "sender@example.org", import_and_trust_key: key)
          end

          assert_match(/\APGP file was not signed by sender@example.org or the imported key: /, error.message)
        end

        it "does not change the trust of the imported key by default" do
          key         = untrusted_pgp_key
          fingerprint = IOStreams::Pgp.primary_fingerprints("untrusted@example.org").first
          levels      = []
          import      = lambda do |key:, trust_level:|
            levels << [key, trust_level]
            fingerprint
          end
          IOStreams::Pgp.stub(:import_and_trust_recipient, import) do
            assert_raises(IOStreams::Pgp::Failure) { read(signed_by_sender, import_and_trust_key: key) }
            assert_raises(IOStreams::Pgp::Failure) { read(signed_by_sender, import_and_trust_key: key, import_and_trust_level: 3) }
          end

          assert_equal [[key, nil], [key, 3]], levels
        end

        it "is supported as a stream option" do
          key  = signed_by_untrusted
          path = IOStreams.path(temp_file.path).stream(:pgp, passphrase: "receiver_passphrase", import_and_trust_key: key)

          assert_equal decrypted, path.read
        end
      end
    end
  end
end
