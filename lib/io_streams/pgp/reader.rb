require "open3"

module IOStreams
  module Pgp
    class Reader < IOStreams::Reader
      def self.option_names
        %i[passphrase ignore_mdc_error verify_first]
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
      #   only known once the whole file has been read. When either check fails,
      #   `IOStreams::Pgp::Failure` is raised after the block has processed the data.
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
      #   and only pass its contents to the block once gpg has checked the file's integrity
      #   and any signature.
      #   Requires local disk space for the decrypted contents, which are deleted afterwards,
      #   and an extra pass over the data.
      #   Default: false
      def self.file(file_name, passphrase: nil, ignore_mdc_error: false, verify_first: false, &)
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
        args += ["--", file_name.to_s]

        command = IOStreams::Pgp.gpg_command(*args)
        IOStreams.logger&.debug { "IOStreams::Pgp::Reader.open: #{command.shelljoin}" }

        return decrypt_then_read(command, file_name, passphrase, &) if verify_first

        # Read decrypted contents from stdout
        Open3.popen3(*command) do |stdin, stdout, stderr, waith_thr|
          stdin.puts(passphrase) if passphrase
          stdin.close
          result =
            begin
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
          raise(Pgp::Failure, "GPG Failed to decrypt file: #{file_name}: #{stderr.read.chomp}") unless waith_thr.value.success?

          result
        end
      end

      # Decrypts the file into a temporary file, and only yields it once gpg has succeeded.
      def self.decrypt_then_read(command, file_name, passphrase, &block)
        Utils.private_temp_file("iostreams_pgp") do |temp_file_name|
          Open3.popen3(*command) do |stdin, stdout, stderr, waith_thr|
            stdin.puts(passphrase) if passphrase
            stdin.close
            ::File.open(temp_file_name, "wb") { |io| ::IO.copy_stream(stdout, io) }
            unless waith_thr.value.success?
              raise(Pgp::Failure, "GPG Failed to decrypt file: #{file_name}: #{stderr.read.chomp}")
            end
          end

          ::File.open(temp_file_name, "rb", &block)
        end
      end
      private_class_method :decrypt_then_read
    end
  end
end
