require 'open3'

module IOStreams
  module Pgp
    class Reader
      # Passphrase to use to open the private key to decrypt the received file
      def self.default_passphrase=(default_passphrase)
        @default_passphrase = default_passphrase
      end

      # Read from a PGP / GPG file or stream, decompressing the contents as it is read
      # file_name_or_io: [String|IO]
      #   Name of file to read from
      #   Or, the IO stream to receive the decrypted contents
      # passphrase: [String]
      #   Pass phrase for private key to decrypt the file with
      def self.open(file_name_or_io, passphrase: self.default_passphrase, binary: true)
        raise(ArgumentError, 'Missing both passphrase and IOStreams::Pgp::Reader.default_passphrase') unless passphrase

        if IOStreams.reader_stream?(file_name_or_io)
          raise(NotImplementedError, 'Can only PGP Decrypt directly from a file name. Input streams are not yet supported.')
        else
          loopback = IOStreams::Pgp.pgp_version.to_f >= 2.1 ? '--pinentry-mode loopback' : ''
          command  = "#{IOStreams::Pgp.executable} #{loopback} --batch --no-tty --yes --decrypt --passphrase-fd 0 #{file_name_or_io}"
          IOStreams::Pgp.logger.debug { "IOStreams::Pgp::Reader.open: #{command}" } if IOStreams::Pgp.logger

          # Read decrypted contents from stdout
          Open3.popen3(command) do |stdin, stdout, stderr, waith_thr|
            stdin.puts(passphrase) if passphrase
            stdin.close
            result =
              begin
                stdout.binmode if binary
                yield(stdout)
              rescue Errno::EPIPE
                # Ignore broken pipe because gpg terminates early due to an error
                raise(Pgp::Failure, "GPG Failed reading from encrypted file: #{file_name_or_io}: #{stderr.read.chomp}")
              end
            raise(Pgp::Failure, "GPG Failed to decrypt file: #{file_name_or_io}: #{stderr.read.chomp}") unless waith_thr.value.success?
            result
          end
        end
      end

      private

      @default_passphrase = nil

      def self.default_passphrase
        @default_passphrase
      end
    end
  end
end
