module IOStreams
  module Pgp
    class Writer < IOStreams::Writer
      # File descriptor in the gpg process that the signer passphrase is read from.
      PASSPHRASE_FD = 3

      def self.option_names
        %i[encrypt recipient import_and_trust_key import_and_trust_level signer signer_passphrase
           compress compress_level]
      end

      def self.sensitive_option_names
        %i[signer_passphrase]
      end

      class << self
        # Sign all encrypted files with this users key.
        # Default: Do not sign encrypted files.
        attr_writer :default_signer

        # Passphrase to use to open the private key when signing the file.
        # Default: None.
        attr_writer :default_signer_passphrase

        # Encrypt all pgp output files with this recipient for audit purposes.
        # Allows the generated pgp files to be decrypted with this email address.
        # Useful for audit or problem resolution purposes.
        attr_accessor :audit_recipient

        private

        attr_reader :default_signer_passphrase, :default_signer

        @default_signer_passphrase = nil
        @default_signer            = nil
        @audit_recipient           = nil
      end

      # Write to a PGP / GPG stream, encrypting and/or signing the contents as it is written.
      #
      # The block writes to an IO-like stream, which responds to `write`, `<<`, `print`, `puts` and `printf`. What gpg
      # writes to its stdout is written to the output stream as the block writes, in the caller's thread, so that it
      # is never written to a temp file, see `IOStreams::Pgp::GpgProcess`. The output stream is not closed, since it
      # belongs to the caller.
      #
      # Since the data is streamed, when gpg fails part way, or when the block raises, the output stream holds what
      # gpg wrote until then, which is not a valid PGP message: when the block raises, gpg is stopped, so that it never
      # completes a PGP message from partial data, and `IOStreams::Pgp::Reader` raises for the start of a message.
      # As with any other stream, discard the output after a failure; a local path does so already.
      #
      # output_stream: [IO]
      #   The stream to write the PGP data to.
      #
      # encrypt: [true|false]
      #   Whether to encrypt the file for the supplied recipient(s).
      #   When set to false the file is signed but not encrypted, in which case a
      #   :signer must be supplied and :recipient / :import_and_trust_key are ignored.
      #   Default: true
      #
      # recipient: [String|Array<String>]
      #   One or more emails of users for which to encrypt the file.
      #   Ignored when encrypt is false.
      #
      # import_and_trust_key: [String|Array<String>]
      #   One or more pgp keys to import and then use to encrypt the file.
      #   Note: Ascii Keys can contain multiple keys, only the last one in the file is used.
      #
      # import_and_trust_level: [Integer]
      #   The owner-trust level to assign to keys supplied via :import_and_trust_key.
      #     1 : Undefined  (no opinion)
      #     2 : Never      (do not trust)
      #     3 : Marginal
      #     4 : Full
      #     5 : Ultimate
      #   Default: 5 : Ultimate
      #
      #   SECURITY WARNING:
      #     Only import and trust keys received from a verified, trusted source.
      #     The default trust level is `5` (Ultimate), which tells GPG to treat the imported key
      #     as if it were one of your own keys. An ultimately trusted key is implicitly valid and
      #     can in turn confer validity on other keys it has signed. Importing an attacker supplied
      #     key at this level allows that attacker to impersonate other recipients.
      #     When the key cannot be fully verified, supply a lower `import_and_trust_level`.
      #
      # signer: [String]
      #   Name of user with which to sign the encypted file.
      #   Default: default_signer or do not sign.
      #
      # signer_passphrase: [String]
      #   Passphrase to use to open the private key when signing the file.
      #   Default: default_signer_passphrase
      #
      # compress: [:none|:zip|:zlib|:bzip2]
      #   Note: Standard PGP only supports :zip.
      #   :zlib is better than zip.
      #   :bzip2 is best, but uses a lot of memory and is much slower.
      #   Default: :zip
      #
      # compress_level: [Integer]
      #   Compression level
      #   Default: 6
      #
      # Note: There is intentionally no option here to disable MDC (Modification Detection
      # Code) integrity protection on the files we produce. The reader exposes
      # `ignore_mdc_error:` so we can *consume* legacy files that lack MDC (see Reader),
      # but we never want to *generate* them: MDC is what protects the encrypted contents
      # against tampering, and modern GnuPG mandates it for current ciphers anyway
      # (`--disable-mdc` is a no-op unless an obsolete cipher is forced). Omitting MDC on
      # output would only weaken files we create, with no upside for this library.
      def self.stream(output_stream,
                      encrypt: true,
                      recipient: nil,
                      import_and_trust_key: nil,
                      import_and_trust_level: 5,
                      signer: default_signer,
                      signer_passphrase: default_signer_passphrase,
                      compress: :zip,
                      compress_level: 6,
                      &block)
        if encrypt
          raise(ArgumentError, "Requires either :recipient or :import_and_trust_key") unless recipient || import_and_trust_key
        elsif !signer
          raise(ArgumentError, "Requires a :signer when encrypt is false")
        end

        compress_level = 0 if compress == :none

        recipients, imported = encrypt ? collect_recipients(recipient, import_and_trust_key, import_and_trust_level) : [[], []]
        with_recipient_files(recipients, imported) do |all_recipients, recipient_files|
          # Write to stdin, with the encrypted and/or signed contents being written to stdout
          args = build_args(
            encrypt:           encrypt,
            signer:            signer,
            signer_passphrase: signer_passphrase,
            compress:          compress,
            compress_level:    compress_level,
            recipients:        all_recipients,
            recipient_files:   recipient_files
          )
          run(output_stream, args, signer_passphrase, &block)
        end
      end

      # Runs gpg with the supplied arguments, yielding the stream that it encrypts, and returns the result of the block.
      # Raises Pgp::Failure once gpg finishes when it fails.
      def self.run(output_stream, args, signer_passphrase)
        command = IOStreams::Pgp.gpg_command(*args)
        IOStreams.logger&.debug { "IOStreams::Pgp::Writer.open: #{command.shelljoin}" }

        # Since stdin carries the data, supply the signer passphrase on file descriptor 3
        # so that it is not visible in the process list.
        passphrases = signer_passphrase ? {PASSPHRASE_FD => signer_passphrase} : {}
        IOStreams::Pgp::GpgProcess.run(command, failure: "GPG Failed to create encrypted", output: output_stream,
                                                passphrases: passphrases) do |gpg|
          result = yield(gpg.writer)
          gpg.finish
          result
        end
      end
      private_class_method :run

      def self.build_args(encrypt:, signer:, signer_passphrase:, compress:, compress_level:, recipients:, recipient_files:)
        args = ["--batch", "--no-tty", "--yes"]
        args << "--encrypt" if encrypt
        args += ["--sign", "--local-user", IOStreams::Pgp.user_id(signer)] if signer
        args += [*IOStreams::Pgp.passphrase_args, "--passphrase-fd", PASSPHRASE_FD.to_s] if signer_passphrase
        args += ["-z", compress_level.to_s] if compress_level != 6
        args += ["--compress-algo", compress.to_s] unless compress == :none
        recipients.each { |address| args += ["--recipient", IOStreams::Pgp.user_id(address)] }
        recipient_files.each { |recipient_file| args += ["--recipient-file", recipient_file] }
        args
      end
      private_class_method :build_args

      # Returns [Array<Array<String>>] the recipients, and the fingerprints of the keys imported via
      # `import_and_trust_key`, or other recipients for them when gpg does not supply a fingerprint.
      def self.collect_recipients(recipient, import_and_trust_key, import_and_trust_level)
        recipients = Array(recipient)
        recipients << audit_recipient if audit_recipient

        imported = Array(import_and_trust_key).map do |key|
          IOStreams::Pgp.import_and_trust_recipient(key: key, trust_level: import_and_trust_level)
        end
        [recipients, imported]
      end
      private_class_method :collect_recipients

      # Yields the recipients, and the names of files that each hold one of the imported keys.
      #
      # gpg only encrypts to a key in the keyring that is valid, which on its own requires ultimate trust,
      # so an imported key with a lower `import_and_trust_level` could not be encrypted to. gpg treats a key
      # in a file supplied via `--recipient-file` as valid without changing its trust, so each imported key
      # is exported by its fingerprint, which also ensures that the imported key is the one used, since
      # another key in the keyring could have the same email address.
      #
      # gpg before v2.1.14 does not support `--recipient-file`, so the imported keys are recipients instead.
      def self.with_recipient_files(recipients, imported, &)
        files       = IOStreams::Pgp.recipient_file?
        keys, other = imported.partition { |value| files && IOStreams::Pgp.fingerprint?(value) }
        write_recipient_files(keys, [], recipients + other, &)
      end
      private_class_method :with_recipient_files

      def self.write_recipient_files(fingerprints, recipient_files, recipients, &block)
        return yield(recipients, recipient_files) if fingerprints.empty?

        Utils.private_temp_file("iostreams_pgp_key", purpose: "an imported key, for gpg --recipient-file") do |recipient_file|
          ::File.binwrite(recipient_file, IOStreams::Pgp.export(key_id: fingerprints.first, ascii: false))
          write_recipient_files(fingerprints.drop(1), recipient_files + [recipient_file], recipients, &block)
        end
      end
      private_class_method :write_recipient_files
    end
  end
end
