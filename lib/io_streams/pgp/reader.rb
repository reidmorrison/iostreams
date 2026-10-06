require "open3"

module IOStreams
  module Pgp
    class Reader < IOStreams::Reader
      # File descriptor in the gpg process that its status is written to, when checking the signer.
      STATUS_FD = 3

      # Trust levels of a signer's key that gpg reports for a key that is valid.
      TRUSTED = %w[TRUST_FULLY TRUST_ULTIMATE].freeze

      def self.option_names
        %i[passphrase signer import_and_trust_key import_and_trust_level ignore_mdc_error verify_first]
      end

      # Also the writer's options that reading does not need: gpg reads both encrypted and signed-only
      # files, decrypts with the private key of whichever recipient the file was encrypted for, and reads
      # how it was compressed from the file. `signer_passphrase` only applies to signing.
      def self.valid_option_names
        option_names + %i[encrypt recipient signer_passphrase compress compress_level]
      end

      # Passphrase to use to open the private key to decrypt the received file
      class << self
        attr_writer :default_passphrase

        private

        attr_reader :default_passphrase

        @default_passphrase = nil
      end

      # Read from a PGP / GPG file , decompressing the contents as it is read.
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
      # file_name: [String]
      #   Name of file to read from
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
      def self.file(file_name,
                    passphrase: nil,
                    signer: nil,
                    import_and_trust_key: nil,
                    import_and_trust_level: nil,
                    ignore_mdc_error: false,
                    verify_first: false,
                    &)
        # Cannot use `passphrase: self.default_passphrase` since it is considered private
        passphrase ||= default_passphrase

        # Find the signer's keys, and import the supplied keys, before decrypting,
        # so that a missing or invalid key fails before any data is read.
        signers = expected_signers(signer, import_and_trust_key, import_and_trust_level)
        check   = signers.empty? ? nil : ->(status) { verify_signers(file_name, signers, status) }

        args = []
        # Use --pinentry-mode loopback for all GnuPG versions >= 2.1
        args += ["--pinentry-mode", "loopback"] if IOStreams::Pgp.pgp_version.to_f >= 2.1
        # Use --no-symkey-cache for GnuPG versions >= 2.4 to avoid caching session keys
        args << "--no-symkey-cache" if IOStreams::Pgp.pgp_version.to_f >= 2.4
        args << "--ignore-mdc-error" if ignore_mdc_error
        args += ["--status-fd", STATUS_FD.to_s] if check
        args += ["--batch", "--no-tty", "--yes", "--decrypt"]
        # Only feed a passphrase when one is supplied; sign-only files need none.
        args += ["--passphrase-fd", "0"] if passphrase
        args += ["--", file_name.to_s]

        command = IOStreams::Pgp.gpg_command(*args)
        IOStreams.logger&.debug { "IOStreams::Pgp::Reader.open: #{command.shelljoin}" }

        decrypt = ->(&block) { run(command, file_name, passphrase, check, &block) }
        return decrypt_then_read(decrypt, &) if verify_first

        # Read decrypted contents from stdout
        decrypt.call do |stdout, stderr|
          stdout.binmode
          value = yield(stdout)
          # When the block does not read to the end, gpg waits to write the rest, so it would never finish.
          # Read the rest so that gpg finishes, and checks the integrity and signature of the whole file.
          ::IO.copy_stream(stdout, ::File::NULL)
          value
        rescue Errno::EPIPE
          # Ignore broken pipe because gpg terminates early due to an error
          raise(Pgp::Failure, "GPG Failed reading from encrypted file: #{file_name}: #{stderr.read.chomp}")
        end
      end

      # Decrypts the file into a temporary file, and only yields it once gpg has succeeded.
      def self.decrypt_then_read(decrypt, &block)
        Utils.private_temp_file("iostreams_pgp") do |temp_file_name|
          decrypt.call { |stdout, _stderr| ::File.open(temp_file_name, "wb") { |io| ::IO.copy_stream(stdout, io) } }

          ::File.open(temp_file_name, "rb", &block)
        end
      end
      private_class_method :decrypt_then_read

      # Runs gpg, yielding its stdout and stderr, and returns the result of the block.
      # Raises Pgp::Failure once gpg finishes when it fails, or when `check` raises for gpg's status output.
      def self.run(command, file_name, passphrase, check)
        status_reader, status_writer = IO.pipe if check
        spawn_options                = check ? {STATUS_FD => status_writer} : {}

        Open3.popen3(*command, spawn_options) do |stdin, stdout, stderr, waith_thr|
          # Only the gpg process writes its status.
          status_writer&.close
          # Read the status while gpg runs, so that gpg never waits for it to be read.
          status = Thread.new { status_reader.read } if check
          status&.report_on_exception = false

          stdin.puts(passphrase) if passphrase
          stdin.close
          result = yield(stdout, stderr)
          raise(Pgp::Failure, "GPG Failed to decrypt file: #{file_name}: #{stderr.read.chomp}") unless waith_thr.value.success?

          check&.call(status.value)
          result
        end
      ensure
        status_writer&.close
        status_reader&.close
      end
      private_class_method :run

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
        return fingerprint.upcase if fingerprint.match?(/\A(\h{40}|\h{64})\z/)

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
        raise(Pgp::Failure, "PGP file was not signed by #{names}: #{file_name}") if matches.empty?

        raise(Pgp::Failure,
              "PGP file was signed by #{matches.first.first.name}, but gpg does not trust the key, " \
              "see IOStreams::Pgp.set_trust: #{file_name}")
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
