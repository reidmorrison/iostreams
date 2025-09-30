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
      #   Pass phrase for private key to decrypt the file with
      def self.file(file_name, passphrase: nil)
        # Cannot use `passphrase: self.default_passphrase` since it is considered private
        passphrase ||= default_passphrase
        raise(ArgumentError, "Missing both passphrase and IOStreams::Pgp::Reader.default_passphrase") unless passphrase

        # Use --pinentry-mode loopback for all GnuPG versions >= 2.1
        loopback = IOStreams::Pgp.pgp_version.to_f >= 2.1 ? "--pinentry-mode loopback" : ""

        # Use --no-symkey-cache for GnuPG versions >= 2.4 to avoid caching session keys
        no_symkey_cache = IOStreams::Pgp.pgp_version.to_f >= 2.4 ? "--no-symkey-cache" : ""

        command  = "#{IOStreams::Pgp.executable} #{loopback} #{no_symkey_cache} --batch --no-tty --yes --decrypt --passphrase-fd 0 #{file_name}"
        IOStreams::Pgp.logger&.debug { "IOStreams::Pgp::Reader.open: #{command}" }

        # Read decrypted contents from stdout
        Open3.popen3(command) do |stdin, stdout, stderr, waith_thr|
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