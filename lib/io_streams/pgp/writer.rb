require "open3"

module IOStreams
  module Pgp
    class Writer < IOStreams::Writer
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

      # Write to a PGP / GPG file, encrypting the contents as it is written.
      #
      # file_name: [String]
      #   Name of file to write to.
      #
      # recipient: [String|Array<String>]
      #   One or more emails of users for which to encrypt the file.
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
      def self.file(file_name,
                    recipient: nil,
                    import_and_trust_key: nil,
                    import_and_trust_level: 5,
                    signer: default_signer,
                    signer_passphrase: default_signer_passphrase,
                    compress: :zip,
                    compression: nil, # Deprecated
                    compress_level: 6)

        raise(ArgumentError, "Requires either :recipient or :import_and_trust_key") unless recipient || import_and_trust_key

        # Backward compatibility
        compress = compression if compression

        compress_level = 0 if compress == :none

        recipients = Array(recipient)
        recipients << audit_recipient if audit_recipient

        Array(import_and_trust_key).each do |key|
          recipients << IOStreams::Pgp.import_and_trust(key: key, trust_level: import_and_trust_level)
        end

        # Write to stdin, with encrypted contents being written to the file
        args = ["--batch", "--no-tty", "--yes", "--encrypt"]
        args += ["--sign", "--local-user", signer.to_s] if signer
        if signer_passphrase
          args += ["--pinentry-mode", "loopback"] if IOStreams::Pgp.pgp_version.to_f >= 2.1
          args << "--no-symkey-cache" if IOStreams::Pgp.pgp_version.to_f >= 2.4
          args += ["--passphrase", signer_passphrase.to_s]
        end
        args += ["-z", compress_level.to_s] if compress_level != 6
        args += ["--compress-algo", compress.to_s] unless compress == :none
        recipients.each { |address| args += ["--recipient", address.to_s] }
        args += ["-o", file_name.to_s]
        command = IOStreams::Pgp.gpg_command(*args)

        # Do not log the command, it may contain the signer passphrase.
        IOStreams::Pgp.logger&.debug { "IOStreams::Pgp::Writer.open: encrypt -o #{file_name}" }

        result = nil
        Open3.popen2e(*command) do |stdin, out, waith_thr|
          begin
            stdin.binmode
            result = yield(stdin)
            stdin.close
          rescue Errno::EPIPE
            # Ignore broken pipe because gpg terminates early due to an error
            ::File.delete(file_name) if ::File.exist?(file_name)
            raise(Pgp::Failure, "GPG Failed writing to encrypted file: #{file_name}: #{out.read.chomp}")
          end
          unless waith_thr.value.success?
            ::File.delete(file_name) if ::File.exist?(file_name)
            raise(Pgp::Failure, "GPG Failed to create encrypted file: #{file_name}: #{out.read.chomp}")
          end
        end
        result
      end
    end
  end
end