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

  # A stream that records whether a read was stopped part way through, which slows each read
  # so that the block can raise while one is in progress.
  class SlowInput
    attr_reader :interrupted

    def initialize(data)
      @io          = StringIO.new(data)
      @interrupted = false
    end

    def read(length = nil, outbuf = nil)
      # Not reset in an ensure, since Thread#kill runs it.
      @interrupted = true
      sleep(0.01)
      data         = @io.read(length, outbuf)
      @interrupted = false
      data
    end
  end

  # A stream that returns the first half of the data, and then raises, like compressed data that is corrupt part way.
  class TruncatedInput
    def initialize(data)
      @io = StringIO.new(data.byteslice(0, data.bytesize / 2))
    end

    def read(length = nil, outbuf = nil)
      @io.read(length, outbuf) || raise(Zlib::DataError, "invalid compressed data")
    end
  end

  # A stream that returns the start of the data, and then raises Errno::EPIPE, like a stream that reads from a
  # program that exited.
  class BrokenPipeInput < CorruptInput
    def read(length = nil, outbuf = nil)
      raise(Errno::EPIPE, "reading the input") if @read

      super
    end
  end

  # A stream over an Enumerator of blocks, read with `Enumerator#next`, such as a streamed HTTP download.
  # It reads its first block when it is created, so it can only be read by the thread that created it.
  class ChunkedInput
    def initialize(data)
      @blocks = data.b.scan(/.{1,4096}/m).each
      @buffer = @blocks.next.dup
    end

    def read(length = nil, outbuf = nil)
      data = +""
      while @buffer && (length.nil? || data.bytesize < length)
        take    = length ? length - data.bytesize : @buffer.bytesize
        data   << @buffer.byteslice(0, take)
        @buffer = @buffer.byteslice(take..) || +""
        @buffer = next_block if @buffer.empty?
      end
      return if data.empty? && length&.positive?

      outbuf ? outbuf.replace(data) : data
    end

    private

    def next_block
      @blocks.next.dup
    rescue StopIteration
      nil
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
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") { |io| io.write(decrypted) }

        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "BAD", &:read)
        end

        assert_includes error.message, "Bad passphrase"
      end

      it "fails without a passphrase" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") { |io| io.write(decrypted) }

        error = assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp::Reader.file(temp_file.path, &:read) }

        assert_match(/\AGPG Failed to decrypt file: /, error.message)
      end

      it "decrypts with the default passphrase when none is supplied" do
        IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") { |io| io.write(decrypted) }
        IOStreams::Pgp::Reader.default_passphrase = "receiver_passphrase"

        assert_equal decrypted, IOStreams::Pgp::Reader.file(temp_file.path, &:read)
      ensure
        IOStreams::Pgp::Reader.default_passphrase = nil
      end

      describe "ignore_mdc_error" do
        # Encrypted with the passphrase "legacy" and without the modification detection code (MDC) that protects the
        # contents from being changed, as legacy programs write it, with `gpg --symmetric --rfc2440`.
        let(:without_mdc) { File.join(__dir__, "files", "without_mdc.txt.pgp") }

        it "is required to decrypt a file without integrity protection" do
          error = assert_raises(IOStreams::Pgp::Failure) do
            IOStreams::Pgp::Reader.file(without_mdc, passphrase: "legacy", &:read)
          end

          assert_includes error.message, "--ignore-mdc-error"
        end

        it "decrypts a file without integrity protection" do
          result = IOStreams::Pgp::Reader.file(without_mdc, passphrase: "legacy", ignore_mdc_error: true, &:read)

          assert_equal "Encrypted without integrity protection\n", result
        end

        it "decrypts a file with integrity protection" do
          IOStreams::Pgp::Writer.file(temp_file.path, recipient: "receiver@example.org") do |io|
            io.write(decrypted)
          end

          result = IOStreams::Pgp::Reader.file(temp_file.path, passphrase: "receiver_passphrase", ignore_mdc_error: true, &:read)

          assert_equal decrypted, result
        end

        it "is supported as a stream option" do
          path = IOStreams.path(without_mdc).option(:pgp, passphrase: "legacy", ignore_mdc_error: true)

          assert_equal "Encrypted without integrity protection\n", path.read
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
        assert_operator input.pos, :<, input.size
        refute_predicate input, :closed?
      end

      it "does not stop part way through reading the stream when the block raises" do
        input = SlowInput.new(encrypt(large_data))

        Timeout.timeout(30) do
          assert_raises(ArgumentError) do
            IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase") do |io|
              io.read(10)
              raise(ArgumentError, "from the block")
            end
          end
        end

        refute input.interrupted
      end

      it "reads a local file through its file descriptor, leaving the file at its end" do
        File.binwrite(temp_file.path, encrypt(decrypted))
        File.open(temp_file.path, "rb") do |file|
          result = temp_files_created do
            assert_equal decrypted, IOStreams::Pgp::Reader.stream(file, passphrase: "receiver_passphrase", &:read)
          end

          assert_empty result
          assert_predicate file, :eof?
          refute_predicate file, :closed?
        end
      end

      it "reads a local file from where the caller has read to" do
        encrypted = encrypt(decrypted)
        File.binwrite(temp_file.path, "header\n".b + encrypted)
        File.open(temp_file.path, "rb") do |file|
          # Ruby reads ahead into its buffer, so that the file's position is past the start of the PGP data.
          assert_equal "header\n", file.gets
          assert_equal decrypted, IOStreams::Pgp::Reader.stream(file, passphrase: "receiver_passphrase", &:read)
        end
      end

      it "reads the file of a Tempfile through its file descriptor, naming it when gpg fails" do
        temp_file.write("Not a PGP file")
        temp_file.flush
        temp_file.rewind
        error = assert_raises(IOStreams::Pgp::Failure) do
          IOStreams::Pgp::Reader.stream(temp_file, passphrase: "receiver_passphrase", &:read)
        end

        assert_match(/\AGPG Failed to decrypt file: #{Regexp.escape(File.absolute_path(temp_file.path))}: /, error.message)
      end

      it "raises for a local file that was not opened for reading" do
        File.binwrite(temp_file.path, encrypt(decrypted))
        File.open(temp_file.path, "ab") do |file|
          Timeout.timeout(30) do
            assert_raises(IOError) { IOStreams::Pgp::Reader.stream(file, passphrase: "receiver_passphrase", &:read) }
          end
        end
      end

      it "does not wait for gpg's stderr to be read" do
        result = Timeout.timeout(30) do
          with_gpg_stub(NOISY_GPG) { IOStreams::Pgp::Reader.stream(StringIO.new(decrypted), &:read) }
        end

        assert_equal decrypted, result
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

      it "reads a stream that can only be read by the thread that created it" do
        result = Timeout.timeout(30) do
          IOStreams::Pgp::Reader.stream(ChunkedInput.new(encrypt(large_data)), passphrase: "receiver_passphrase", &:read)
        end

        assert_equal large_data, result
      end

      it "reads lines with gets and each_line" do
        lines = "first\nsecond\nthird"
        input = StringIO.new(encrypt(lines))
        IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase") do |io|
          assert_equal "first\n", io.gets
          assert_equal %W[second\n third], io.each_line.to_a
          assert_nil io.gets
          assert_predicate io, :eof?
        end
      end

      describe "the stream that the block reads" do
        # Returns the result of the block, which reads the decrypted data, once it has checked that the block returns
        # the same result whether gpg reads a local file, when the block reads gpg's stdout, which is an IO, or any
        # other stream, when the block reads a StdoutReader, which must behave like an IO.
        def read_as_file_and_stream(data, &block)
          encrypted   = encrypt(data)
          from_stream = IOStreams::Pgp::Reader.stream(StringIO.new(encrypted), passphrase: "receiver_passphrase") do |io|
            assert_instance_of IOStreams::Pgp::GpgProcess::StdoutReader, io
            block.call(io)
          end
          from_file = File.open(temp_file.path, "rb") do |file|
            IOStreams::Pgp::Reader.stream(file, passphrase: "receiver_passphrase") do |io|
              assert_instance_of IO, io
              block.call(io)
            end
          end

          assert_equal from_file, from_stream
          from_stream
        end

        it "reads like IO#read" do
          # More than gpg writes to its stdout at a time.
          data    = Array.new(20_000) { |i| "line #{i}\n" }.join
          results = read_as_file_and_stream(data) do |io|
            # Each read has its own buffer, since the block returns it.
            buffer = +"previous"
            [
              io.read(0), io.read(3), io.read(150_000) == data.byteslice(3, 150_000), io.read(5, buffer).dup, buffer.dup,
              io.read == data.byteslice(150_008..), io.read(0), io.read, io.read(5, buffer), buffer
            ]
          end

          assert_equal ["", "lin", true, data.byteslice(150_003, 5), data.byteslice(150_003, 5), true, "", "", nil, ""], results
        end

        it "reads lines like IO#gets" do
          data    = "first\nsecond\nthird line\nfourth\n\n\n\nfifth paragraph\n\nlast"
          results = read_as_file_and_stream(data) do |io|
            [
              io.gets, io.gets(chomp: true), io.gets("d"), io.gets(4), io.gets("\n", 3), io.gets(nil, 5), io.gets(""),
              io.gets("", chomp: true), io.gets(""), io.gets, io.eof?
            ]
          end

          assert_equal ["first\n", "second", "third", " lin", "e\n", "fourt", "h\n\n", "fifth paragraph", "last", nil, true], results
        end

        it "reads paragraphs like IO#each_line" do
          results = read_as_file_and_stream("\n\nfirst\n\n\n\nsecond\n\nthird\n") do |io|
            # With a block, since on JRuby the Enumerator that IO#each_line returns does not accept `chomp:`.
            lines = []
            io.each_line("", chomp: true) { |line| lines << line }
            lines
          end

          assert_equal %W[first second third\n], results
        end

        it "skips the line endings after a paragraph like IO#gets" do
          results = read_as_file_and_stream("first\n\n\n\nrest") { |io| [io.gets(""), io.read] }

          assert_equal %W[first\n\n rest], results
        end

        it "reads what is available like IO#readpartial" do
          results = read_as_file_and_stream("abcdef") do |io|
            first = io.readpartial(4)
            rest  = io.read
            eof   = begin
              io.readpartial(1)
            rescue EOFError
              :eof
            end
            [first, rest, eof]
          end

          assert_equal ["abcd", "ef", :eof], results
        end

        it "reports the end of the data like IO#eof?" do
          results = read_as_file_and_stream("abcdef") { |io| [io.eof?, io.read(3), io.eof?, io.read, io.eof?] }

          assert_equal [false, "abc", false, "def", true], results
        end
      end

      describe "trust in the signer's key" do
        let(:fingerprint) { "A" * 40 }

        # Returns [String] the data read with a stub gpg, which reports a good signature by a subkey of the key with
        # the fingerprint, followed by the supplied trust that gpg has in the key.
        def read_signed(trust, signed_by: fingerprint)
          script = <<~SCRIPT
            echo "[GNUPG:] PLAINTEXT 62 0" >&3
            echo "[GNUPG:] VALIDSIG #{'B' * 40} 2026-10-10 1791590400 0 4 0 1 10 00 #{signed_by}" >&3
            echo "[GNUPG:] #{trust} 0 pgp" >&3
            cat
          SCRIPT
          IOStreams::Pgp.stub(:primary_fingerprints, [fingerprint]) do
            with_gpg_stub(script) { IOStreams::Pgp::Reader.stream(StringIO.new("data"), signer: "jack@example.org", &:read) }
          end
        end

        %w[TRUST_FULLY TRUST_ULTIMATE].each do |trust|
          it "accepts a signature by a key with #{trust}" do
            assert_equal "data", read_signed(trust)
          end
        end

        %w[TRUST_UNDEFINED TRUST_NEVER TRUST_MARGINAL].each do |trust|
          it "rejects a signature by a key with #{trust}" do
            error = assert_raises(IOStreams::Pgp::Failure) { read_signed(trust) }

            assert_equal "PGP stream was signed by jack@example.org, but gpg does not trust the key, " \
                         "see IOStreams::Pgp.set_trust", error.message
          end
        end

        it "rejects a signature by another key" do
          error = assert_raises(IOStreams::Pgp::Failure) { read_signed("TRUST_ULTIMATE", signed_by: "C" * 40) }

          assert_equal "PGP stream was not signed by jack@example.org", error.message
        end
      end

      it "raises the failure to read the stream, rather than the block's failure on the data cut short by it" do
        # Random values, which gpg cannot compress, so that the data is cut part way through.
        rows  = (1..50_000).map { |i| "#{i.to_s.rjust(6, '0')},#{Random.new(i).bytes(10).unpack1('H*')}" }
        input = TruncatedInput.new(encrypt(rows.join("\n")))
        error = Timeout.timeout(30) do
          assert_raises(Zlib::DataError) do
            IOStreams.stream(input).stream(:pgp, passphrase: "receiver_passphrase").each(:line) do |line|
              raise(ArgumentError, "Truncated row: #{line}") unless line.size == 27
            end
          end
        end

        assert_equal "invalid compressed data", error.message
      end

      it "raises a broken pipe when reading the stream, rather than ignoring the rest of the stream" do
        input = BrokenPipeInput.new(encrypt(decrypted))

        Timeout.timeout(30) do
          assert_raises(Errno::EPIPE) { IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase", &:read) }
        end
      end

      it "raises for the start of a PGP message, rather than reading it as empty" do
        encrypted = encrypt(decrypted)
        [4, 100, 250].each do |size|
          error = assert_raises(IOStreams::Pgp::Failure) do
            IOStreams::Pgp::Reader.stream(StringIO.new(encrypted.byteslice(0, size)), passphrase: "receiver_passphrase",
                                          &:read)
          end

          assert_match(/\AGPG Failed to decrypt stream: /, error.message)
        end
      end

      it "can be interrupted by Timeout while the stream stalls" do
        encrypted      = encrypt(large_data)
        reader, writer = IO.pipe
        sender         = Thread.new do
          writer.write(encrypted.byteslice(0, encrypted.bytesize / 2))
        rescue IOError, Errno::EPIPE
          nil
        end

        Timeout.timeout(30) do
          assert_raises(Timeout::Error) do
            Timeout.timeout(1) { IOStreams::Pgp::Reader.stream(reader, passphrase: "receiver_passphrase", &:read) }
          end
        end
      ensure
        reader&.close
        writer&.close
        sender&.join
      end

      it "stops gpg when it is run by a wrapper executable and the block raises" do
        input = StringIO.new(encrypt(large_data))
        Timeout.timeout(30) do
          with_gpg_stub(WRAPPER_GPG) do
            assert_raises(ArgumentError) do
              IOStreams::Pgp::Reader.stream(input, passphrase: "receiver_passphrase") do |io|
                io.read(10)
                raise(ArgumentError, "from the block")
              end
            end
          end
        end
      end

      it "lets gpg remove its lock files when the block raises" do
        input  = encrypt(large_data)
        before = gpg_lock_files

        3.times do
          assert_raises(ArgumentError) do
            IOStreams::Pgp::Reader.stream(StringIO.new(input), passphrase: "receiver_passphrase") do |io|
              io.read(10)
              raise(ArgumentError, "from the block")
            end
          end
        end

        assert_empty gpg_lock_files - before
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
