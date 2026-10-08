require_relative "test_helper"
require "timeout"

class PgpWriterTest < Minitest::Test
  # An output stream that raises when it is written to, like a full disk.
  class FullOutput
    def write(*)
      raise(Errno::ENOSPC, "writing the output")
    end
  end

  describe IOStreams::Pgp::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decrypted do
      file_name = File.join(File.dirname(__FILE__), "files", "text.txt")
      File.read(file_name)
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "writes encrypted text file" do
        result =
          IOStreams::Pgp::Writer.file(file_name, recipient: "receiver@example.org") do |io|
            io.write(decrypted)
            53_534
          end

        assert_equal 53_534, result

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "writes encrypted binary file" do
        binary_file_name = File.join(File.dirname(__FILE__), "files", "spreadsheet.xlsx")
        binary_data      = File.binread(binary_file_name)

        File.open(binary_file_name, "rb") do |input|
          result =
            IOStreams::Pgp::Writer.file(file_name, recipient: "receiver@example.org") do |output|
              IO.copy_stream(input, output)
              53_534
            end

          assert_equal 53_534, result
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal binary_data, result
      end

      it "writes and signs encrypted file" do
        IOStreams::Pgp::Writer.file(file_name, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "signs without encrypting" do
        IOStreams::Pgp::Writer.file(file_name, encrypt: false, signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
          io.write(decrypted)
        end

        # A signed-only file is not encrypted and so needs no passphrase to read.
        result = IOStreams::Pgp::Reader.file(file_name, &:read)

        assert_equal decrypted, result
      end

      it "raises when signing without encryption and no signer is supplied" do
        assert_raises ArgumentError do
          IOStreams::Pgp::Writer.file(file_name, encrypt: false) { |io| io.write(decrypted) }
        end
      end

      it "supports multiple recipients" do
        IOStreams::Pgp::Writer.file(file_name, recipient: %w[receiver@example.org receiver2@example.org], signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver2_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "encrypts for recipient and audit recipient" do
        IOStreams::Pgp::Writer.stub(:audit_recipient, "receiver2@example.org") do
          IOStreams::Pgp::Writer.file(file_name, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
            io.write(decrypted)
          end
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver2_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "fails with bad signer passphrase" do
        skip "GnuPG v2.1 and above passes when it should not" if IOStreams::Pgp.version_at_least?("2.1")
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.file(file_name, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "BAD") do |io|
            io.write(decrypted)
          end
        end
      end

      it "fails with bad recipient" do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.file(file_name, recipient: "BAD@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
            io.write(decrypted)
            # Allow process to terminate
            sleep 1
            io.write(decrypted)
          end
        end
      end

      it "fails with bad signer" do
        assert_raises IOStreams::Pgp::Failure do
          IOStreams::Pgp::Writer.file(file_name, recipient: "receiver@example.org", signer: "BAD@example.org", signer_passphrase: "sender_passphrase") do |io|
            io.write(decrypted)
          end
        end
      end

      it "writes to a stream" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Pgp::Writer.stream(io_string, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase") do |io|
            io.write(decrypted)
            53_534
          end

        assert_equal 53_534, result

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

      def decrypt(data)
        IOStreams::Pgp::Reader.stream(StringIO.new(data), passphrase: "receiver_passphrase", &:read)
      end

      it "encrypts to a stream that is not a local file through gpg's stdout, without a temp file" do
        output = StringIO.new("".b)
        result = nil
        temps  = temp_files_created do
          result = IOStreams::Pgp::Writer.stream(output, recipient: "receiver@example.org") do |io|
            io.write(large_data)
            53_534
          end
        end

        assert_equal 53_534, result
        assert_empty temps
        refute_predicate output, :closed?
        assert_equal large_data, decrypt(output.string)
      end

      it "raises the failure to write to the stream, rather than the failure of gpg that it causes" do
        error = Timeout.timeout(30) do
          assert_raises(Errno::ENOSPC) do
            IOStreams::Pgp::Writer.stream(FullOutput.new, recipient: "receiver@example.org") { |io| io.write(large_data) }
          end
        end

        assert_match(/writing the output/, error.message)
      end

      it "raises when gpg fails, naming the stream" do
        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Writer.stream(StringIO.new("".b), recipient: "BAD@example.org") do |io|
            io.write(decrypted)
            # Allow process to terminate
            sleep 1
            io.write(decrypted)
          end
        end

        assert_match(/encrypted stream: /, error.message)
      end

      it "encrypts the data that the block wrote before it raised" do
        output = StringIO.new("".b)
        error  = Timeout.timeout(30) do
          assert_raises(ArgumentError) do
            IOStreams::Pgp::Writer.stream(output, recipient: "receiver@example.org") do |io|
              io.write("written before the block raised")
              raise(ArgumentError, "from the block")
            end
          end
        end

        assert_equal "from the block", error.message
        refute_predicate output, :closed?
        assert_equal "written before the block raised", decrypt(output.string)
      end
    end

    describe "signer_passphrase" do
      # Stub gpg that records its arguments and what it reads from the passphrase file descriptor.
      def with_stub_gpg
        Dir.mktmpdir do |dir|
          args_file       = ::File.join(dir, "args")
          passphrase_file = ::File.join(dir, "passphrase")
          executable      = ::File.join(dir, "gpg")
          ::File.write(executable, <<~SCRIPT)
            #!/bin/sh
            printf '%s\n' "$@" > "#{args_file}"
            cat <&#{IOStreams::Pgp::Writer::PASSPHRASE_FD} > "#{passphrase_file}"
            cat > /dev/null
          SCRIPT
          ::File.chmod(0o700, executable)

          # Resolve the version using the real gpg before swapping in the stub.
          IOStreams::Pgp.pgp_version
          original                  = IOStreams::Pgp.executable
          IOStreams::Pgp.executable = executable
          begin
            yield(args_file, passphrase_file)
          ensure
            IOStreams::Pgp.executable = original
          end
        end
      end

      it "is supplied on a file descriptor instead of the command line" do
        with_stub_gpg do |args_file, passphrase_file|
          IOStreams::Pgp::Writer.file(file_name, encrypt: false, signer: "sender@example.org", signer_passphrase: "TOP-SECRET") do |io|
            io.write(decrypted)
          end

          args = ::File.read(args_file).lines.map(&:chomp)

          refute_includes args, "TOP-SECRET"
          assert_equal ["--passphrase-fd", IOStreams::Pgp::Writer::PASSPHRASE_FD.to_s], args[args.index("--passphrase-fd"), 2]
          assert_equal "TOP-SECRET\n", ::File.read(passphrase_file)
        end
      end
    end

    describe "import_and_trust_key" do
      let :public_key do
        IOStreams::Pgp.export(email: "receiver@example.org")
      end

      it "imports and trusts the supplied key at the default ultimate level" do
        captured = {}
        stub = lambda do |**kwargs|
          captured = kwargs
          "receiver@example.org"
        end
        IOStreams::Pgp.stub(:import_and_trust_recipient, stub) do
          IOStreams::Pgp::Writer.file(file_name, import_and_trust_key: public_key) { |io| io.write(decrypted) }
        end

        assert_equal 5, captured[:trust_level]

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "passes the supplied import_and_trust_level through" do
        captured = {}
        stub = lambda do |**kwargs|
          captured = kwargs
          "receiver@example.org"
        end
        IOStreams::Pgp.stub(:import_and_trust_recipient, stub) do
          IOStreams::Pgp::Writer.file(file_name, import_and_trust_key: public_key, import_and_trust_level: 4) do |io|
            io.write(decrypted)
          end
        end

        assert_equal 4, captured[:trust_level]

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "encrypts to an imported key with less than ultimate trust" do
        IOStreams::Pgp::Writer.file(file_name, import_and_trust_key: untrusted_pgp_key, import_and_trust_level: 4) do |io|
          io.write(decrypted)
        end

        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "untrusted_passphrase", &:read)

        assert_equal decrypted, result
      end

      it "encrypts to the fingerprint returned for the imported key" do
        fingerprint = IOStreams::Pgp.list_keys(email: "receiver@example.org").first[:key_id]

        assert_match(/\A\h{40}\z/, fingerprint)

        IOStreams::Pgp.stub(:import_and_trust_recipient, fingerprint) do
          IOStreams::Pgp::Writer.file(file_name, import_and_trust_key: public_key) { |io| io.write(decrypted) }
        end
        result = IOStreams::Pgp::Reader.file(file_name, passphrase: "receiver_passphrase", &:read)

        assert_equal decrypted, result
      end
    end
  end
end
