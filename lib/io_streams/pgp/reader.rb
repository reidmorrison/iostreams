require "open3"

module IOStreams
  module Pgp
    class Reader < IOStreams::Reader
      # Passphrase to use to open the private key to decrypt the received file
      class << self
        attr_writer :default_passphrase

        private

        attr_reader :default_passphrase

        @default_passphrase = nil
      end

      # Read from a PGP / GPG file , decompressing the contents as it is read.
      #
      # file_name: [String]
      #   Name of file to read from
      #
      # passphrase: [String]
      #   Pass phrase for private key to decrypt the file with.
      #   Not required when the file is signed but not encrypted.
      #
      # ignore_mdc_error: [true|false]
      #   Decrypt files that lack MDC (Modification Detection Code) integrity protection.
      #   Some legacy/enterprise systems (e.g. Workday) still produce such files, which
      #   modern GnuPG refuses to decrypt with `gpg: decryption forced to fail!`.
      #   Only enable this for files from a trusted source: without MDC the decrypted
      #   contents are not protected against tampering.
      #   Default: false
      def self.file(file_name, passphrase: nil, ignore_mdc_error: false)
        # Cannot use `passphrase: self.default_passphrase` since it is considered private
        passphrase ||= default_passphrase

        args = []
        # Use --pinentry-mode loopback for all GnuPG versions >= 2.1
        args += ["--pinentry-mode", "loopback"] if IOStreams::Pgp.pgp_version.to_f >= 2.1
        # Use --no-symkey-cache for GnuPG versions >= 2.4 to avoid caching session keys
        args << "--no-symkey-cache" if IOStreams::Pgp.pgp_version.to_f >= 2.4
        args << "--ignore-mdc-error" if ignore_mdc_error
        args += ["--batch", "--no-tty", "--yes", "--decrypt"]
        # Only feed a passphrase when one is supplied; sign-only files need none.
        args += ["--passphrase-fd", "0"] if passphrase
        args << file_name.to_s

        command = IOStreams::Pgp.gpg_command(*args)
        IOStreams::Pgp.logger&.debug { "IOStreams::Pgp::Reader.open: #{command.shelljoin}" }

        # Read decrypted contents from stdout
        Open3.popen3(*command) do |stdin, stdout, stderr, waith_thr|
          stdin.puts(passphrase) if passphrase
          stdin.close
          result =
            begin
              stdout.binmode
              yield(stdout)
            rescue Errno::EPIPE
              # Ignore broken pipe because gpg terminates early due to an error
              raise(Pgp::Failure, "GPG Failed reading from encrypted file: #{file_name}: #{stderr.read.chomp}")
            end
          raise(Pgp::Failure, "GPG Failed to decrypt file: #{file_name}: #{stderr.read.chomp}") unless waith_thr.value.success?

          result
        end
      end
    end
  end
end
