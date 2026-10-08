require "open3"

module IOStreams
  module Pgp
    class Reader < IOStreams::Reader
      # File descriptor in the gpg process that its status is written to, when checking the signer.
      STATUS_FD = 3

      # File descriptor in the gpg process that the passphrase is read from, since stdin can carry the data.
      PASSPHRASE_FD = 4

      # Trust levels of a signer's key that gpg reports for a key that is valid.
      TRUSTED = %w[TRUST_FULLY TRUST_ULTIMATE].freeze

      def self.option_names
        %i[passphrase signer import_and_trust_key import_and_trust_level ignore_mdc_error verify_first]
      end

      def self.sensitive_option_names
        %i[passphrase]
      end

      # Passphrase to use to open the private key to decrypt the received file
      class << self
        attr_writer :default_passphrase

        private

        attr_reader :default_passphrase

        @default_passphrase = nil
      end

      # Read from a PGP / GPG stream, decrypting the contents as it is read.
      #
      # gpg reads a local file itself, by its name, such as a local path, or the temp file of an S3, SFTP or HTTP
      # path, see `IOStreams::Reader.input_file_name`. A thread copies any other stream, such as PGP data within
      # another stream, or a StringIO, to gpg's stdin as the block reads the decrypted contents, so that it is never
      # copied into a temp file. The input stream is not closed, since it belongs to the caller.
      #
      # SECURITY WARNING:
      #   By default the decrypted contents are passed to the block as gpg decrypts them,
      #   before gpg has checked the file's integrity (MDC) and any signature, since those are
      #   only known once the whole file has been read. When either check fails, or the file
      #   was not signed by the `signer`, `IOStreams::Pgp::Failure` is raised after the block
      #   has processed the data.
      #   Do not commit any side effects, such as database updates, until the block returns
      #   without raising, for example by processing the file within a database transaction.
      #   Otherwise supply `verify_first: true`.
      #   When the block returns before reading the whole file, the rest is still decrypted and checked
      #   before the block's result is returned.
      #
      # input_stream: [IO]
      #   The stream to read the PGP data from.
      #
      # passphrase: [String]
      #   Pass phrase for private key to decrypt the file with.
      #   Not required when the file is signed but not encrypted.
      #
      # signer: [String]
      #   Email address, key id or fingerprint of the key that must have signed the file.
      #   Raises `IOStreams::Pgp::Failure` unless the file has a good signature by that key, and gpg
      #   fully or ultimately trusts it, for example after `IOStreams::Pgp.import_and_trust`.
      #   An email address only matches keys with exactly that email address, ignoring case.
      #   Default: Any signature is checked by gpg, but the file need not be signed, and can be
      #   signed by any key in the keyring.
      #
      # import_and_trust_key: [String|Array<String>]
      #   One or more public keys to import, and then require that the file was signed
      #   by one of them, or by the `signer`.
      #   Since the key is supplied, a signature by it is accepted regardless of the trust that gpg
      #   places in the key.
      #   Note: Ascii Keys can contain multiple keys, only the last one in the file is used.
      #
      # import_and_trust_level: [Integer]
      #   The owner-trust level to assign to keys supplied via :import_and_trust_key.
      #     1 : Undefined  (no opinion)
      #     2 : Never      (do not trust)
      #     3 : Marginal
      #     4 : Full
      #     5 : Ultimate
      #   Default: nil, which does not change the trust of the key, since reading does not need it.
      #   Unlike the writer, which defaults to 5 : Ultimate, this leaves a key that is already
      #   trusted as it was.
      #   See the SECURITY WARNING for `import_and_trust_key` in `IOStreams::Pgp::Writer`.
      #
      # ignore_mdc_error: [true|false]
      #   Decrypt files that lack MDC (Modification Detection Code) integrity protection.
      #   Some legacy/enterprise systems (e.g. Workday) still produce such files, which
      #   modern GnuPG refuses to decrypt with `gpg: decryption forced to fail!`.
      #   Only enable this for files from a trusted source: without MDC the decrypted
      #   contents are not protected against tampering.
      #   Default: false
      #
      # verify_first: [true|false]
      #   Decrypt the whole file into a temporary file, only readable by the current user,
      #   and only pass its contents to the block once gpg has checked the file's integrity,
      #   any signature, and who signed it.
      #   Requires local disk space for the decrypted contents, which are deleted afterwards,
      #   and an extra pass over the data.
      #   Default: false
      def self.stream(input_stream,
                      passphrase: nil,
                      signer: nil,
                      import_and_trust_key: nil,
                      import_and_trust_level: nil,
                      ignore_mdc_error: false,
                      verify_first: false,
                      &)
        # Cannot use `passphrase: self.default_passphrase` since it is considered private
        passphrase ||= default_passphrase
        file_name    = input_file_name(input_stream)

        # Find the signer's keys, and import the supplied keys, before decrypting,
        # so that a missing or invalid key fails before any data is read.
        signers = expected_signers(signer, import_and_trust_key, import_and_trust_level)
        check   = signers.empty? ? nil : ->(status) { verify_signers(file_name, signers, status) }

        args = IOStreams::Pgp.passphrase_args
        args << "--ignore-mdc-error" if ignore_mdc_error
        args += ["--status-fd", STATUS_FD.to_s] if check
        args += ["--batch", "--no-tty", "--yes", "--decrypt"]
        # Only feed a passphrase when one is supplied; sign-only files need none.
        args += ["--passphrase-fd", PASSPHRASE_FD.to_s] if passphrase
        # Without a file name, gpg decrypts its stdin.
        args += ["--", file_name] if file_name

        command = IOStreams::Pgp.gpg_command(*args)
        IOStreams.logger&.debug { "IOStreams::Pgp::Reader.open: #{command.shelljoin}" }

        decrypt = ->(&block) { run(command, file_name, file_name ? nil : input_stream, passphrase, check, &block) }
        result  = verify_first ? decrypt_then_read(decrypt, &) : read_decrypted(decrypt, file_name, &)
        # Like `IOStreams::Reader.stream`, leave a local file at its end, as if it had been read through the stream.
        input_stream.seek(0, ::IO::SEEK_END) if file_name
        result
      end

      # Yields gpg's stdout, which holds the decrypted contents, and returns the result of the block.
      def self.read_decrypted(decrypt, file_name)
        decrypt.call do |stdout, stderr|
          stdout.binmode
          value = yield(stdout)
          # When the block does not read to the end, gpg waits to write the rest, so it would never finish.
          # Read the rest so that gpg finishes, and checks the integrity and signature of the whole file.
          ::IO.copy_stream(stdout, ::File::NULL)
          value
        rescue Errno::EPIPE
          # Ignore broken pipe because gpg terminates early due to an error
          raise(Pgp::Failure, "GPG Failed reading from encrypted #{subject(file_name)}: #{stderr.read.chomp}")
        end
      end
      private_class_method :read_decrypted

      # Decrypts the file into a temporary file, and only yields it once gpg has succeeded.
      def self.decrypt_then_read(decrypt, &block)
        Utils.private_temp_file("iostreams_pgp", purpose: "the decrypted data, until gpg has verified it") do |temp_file_name|
          decrypt.call { |stdout, _stderr| ::File.open(temp_file_name, "wb") { |io| ::IO.copy_stream(stdout, io) } }

          ::File.open(temp_file_name, "rb", &block)
        end
      end
      private_class_method :decrypt_then_read

      # Runs gpg, yielding its stdout and stderr, and returns the result of the block.
      # When an input stream is supplied, a thread copies it to gpg's stdin while the block reads gpg's stdout.
      # Raises Pgp::Failure once gpg finishes when it fails, or when `check` raises for gpg's status output.
      def self.run(command, file_name, input_stream, passphrase, check)
        status_reader, status_writer = IO.pipe if check
        passphrase_reader            = IOStreams::Pgp.passphrase_reader(passphrase) if passphrase
        spawn_options                = {STATUS_FD => status_writer, PASSPHRASE_FD => passphrase_reader}.compact

        Open3.popen3(*command, spawn_options) do |stdin, stdout, stderr, waith_thr|
          # Only the gpg process writes its status, and reads the passphrase.
          status_writer&.close
          passphrase_reader&.close
          # Read the status while gpg runs, so that gpg never waits for it to be read.
          status = Thread.new { status_reader.read } if check
          status&.report_on_exception = false

          result = with_input(input_stream, stdin, stdout) { yield(stdout, stderr) }
          unless waith_thr.value.success?
            raise(Pgp::Failure, "GPG Failed to decrypt #{subject(file_name)}: #{stderr.read.chomp}")
          end

          check&.call(status.value)
          result
        end
      ensure
        status_writer&.close
        status_reader&.close
        passphrase_reader&.close
      end
      private_class_method :run

      # Returns the result of the block, which reads gpg's stdout, while a thread copies the input stream, when
      # supplied, to gpg's stdin. Without an input stream, gpg reads the file, so its stdin is closed.
      #
      # Raises the failure to read the input stream, such as corrupt compressed data, rather than the failure of gpg
      # that it causes. When the block raises, gpg's stdout is closed, so that gpg cannot wait for it to be read, and
      # the thread is stopped, so that it no longer reads the input stream, which belongs to the caller.
      def self.with_input(input_stream, stdin, stdout)
        unless input_stream
          stdin.close
          return yield
        end

        input     = copy_input(input_stream, stdin)
        completed = false
        begin
          result    = yield
          completed = true
        ensure
          unless completed
            stdout.close
            input.kill
            input.join
          end
        end
        error = input.value
        raise(error) if error

        result
      end
      private_class_method :with_input

      # Returns [Thread] that copies the input stream to gpg's stdin, and then closes stdin, so that gpg decrypts
      # the data as it is read. Its value is the exception raised when reading the input stream, if any.
      def self.copy_input(input_stream, stdin)
        Thread.new do
          ::IO.copy_stream(input_stream, stdin)
          nil
        rescue Errno::EPIPE
          # gpg stopped reading, since it failed, which is raised once it finishes.
          nil
        rescue StandardError => e
          e
        ensure
          stdin.close
        end
      end
      private_class_method :copy_input

      # Returns [String] what is being decrypted, for an error message: the named file, or the stream.
      def self.subject(file_name)
        file_name ? "file: #{file_name}" : "stream"
      end
      private_class_method :subject

      # Who must have signed the file: the fingerprints of the primary keys, and whether gpg must also trust them.
      Signers = Struct.new(:name, :fingerprints, :trusted)
      private_constant :Signers

      # Returns [Array<Signers>] who must have signed the file, or [] when anyone can.
      def self.expected_signers(signer, import_and_trust_key, import_and_trust_level)
        signers = []
        signers << Signers.new(signer, signer_fingerprints(signer), true) if signer
        Array(import_and_trust_key).each do |key|
          signers << Signers.new("the imported key", [imported_fingerprint(key, import_and_trust_level)], false)
        end
        signers
      end
      private_class_method :expected_signers

      # Returns [Array<String>] the fingerprints of the signer's primary keys.
      def self.signer_fingerprints(signer)
        fingerprints = IOStreams::Pgp.primary_fingerprints(signer)
        raise(Pgp::Failure, "No PGP key found for the signer: #{signer}") if fingerprints.empty?

        fingerprints.map(&:upcase)
      end
      private_class_method :signer_fingerprints

      # Returns [String] the fingerprint of the supplied key, after importing and trusting it.
      def self.imported_fingerprint(key, trust_level)
        fingerprint = IOStreams::Pgp.import_and_trust_recipient(key: key, trust_level: trust_level)
        # Earlier versions of gpg do not supply the fingerprint of the key.
        return fingerprint.upcase if IOStreams::Pgp.fingerprint?(fingerprint)

        raise(Pgp::Failure, "Checking who signed a file with import_and_trust_key requires gpg v2.1 or later")
      end
      private_class_method :imported_fingerprint

      # Raises Pgp::Failure unless gpg's status shows a good signature by one of the signers.
      #
      # For each good signature gpg reports `VALIDSIG`, whose last field is the fingerprint of the primary key,
      # since the file can be signed by one of its subkeys, followed by the trust level of the key.
      #
      # A key found from the `signer` must be trusted by gpg, since another key in the keyring could have the same
      # email address. A key supplied via `import_and_trust_key` is identified by its fingerprint, so it need not be.
      def self.verify_signers(file_name, signers, status)
        signatures = good_signatures(status)
        matches    = signers.flat_map do |signer|
          signatures.select { |signature| signer.fingerprints.include?(signature[:fingerprint]) }.
            map { |signature| [signer, signature] }
        end
        return if matches.any? { |signer, signature| !signer.trusted || TRUSTED.include?(signature[:trust]) }

        names = signers.map(&:name).join(" or ")
        data  = file_name ? "file" : "stream"
        where = file_name ? ": #{file_name}" : ""
        raise(Pgp::Failure, "PGP #{data} was not signed by #{names}#{where}") if matches.empty?

        raise(Pgp::Failure,
              "PGP #{data} was signed by #{matches.first.first.name}, but gpg does not trust the key, " \
              "see IOStreams::Pgp.set_trust#{where}")
      end
      private_class_method :verify_signers

      # Returns [Array<Hash>] the fingerprint of the primary key, and the trust level, of each good signature.
      def self.good_signatures(status)
        signatures = []
        status.each_line do |line|
          fields = line.split
          next unless fields[0] == "[GNUPG:]"

          if fields[1] == "VALIDSIG"
            signatures << {fingerprint: (fields[11] || fields[2]).upcase}
          elsif fields[1].start_with?("TRUST_") && signatures.last
            signatures.last[:trust] ||= fields[1]
          end
        end
        signatures
      end
      private_class_method :good_signatures
    end
  end
end
