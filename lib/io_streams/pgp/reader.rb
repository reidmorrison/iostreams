require 'open3'

module IOStreams
  module Pgp
    class Reader
      # Passphrase to use to open the private key to decrypt the received file
      def self.default_passphrase=(passphrase)
        @default_passphrase = default_passphrase
      end

      # Read from a PGP / GPG file or stream, decompressing the contents as it is read
      # file_name_or_io: [String|IO]
      #   Name of file to read from
      #   Or, the IO stream to receive the decrypted contents
      # passphrase: [String]
      #   Pass phrase for private key to decrypt the file with
      def self.open(file_name_or_io, passphrase: self.default_passphrase)
        raise(ArgumentError, 'Missing both passphrase and IOStreams::Pgp::Reader.default_passphrase') unless passphrase

        if IOStreams.reader_stream?(file_name_or_io)
          raise(NotImplementedError, 'Can only PGP Decrypt directly from a file name. Input streams are not yet supported.')
        else
          # Read decrypted contents from stdout
          Open3.popen3("gpg --batch --no-tty --yes --decrypt --passphrase-fd 0 #{file_name_or_io}") do |stdin, stdout, stderr, waith_thr|
            stdin.puts(passphrase) if passphrase
            stdin.close
            result = yield(stdout)
            raise(Pgp::Failure, "GPG Failed to decrypt file: #{file_name_or_io}: #{stderr.read.chomp}") unless waith_thr.value.success?
            result
          end
        end
      end

      private

      def self.default_passphrase
        @default_passphrase
      end
    end
  end
end
