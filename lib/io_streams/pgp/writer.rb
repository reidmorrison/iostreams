require 'open3'

module IOStreams
  module Pgp
    class Writer
      # Sign all encrypted files with this users key.
      # Default: Do not sign encyrpted files.
      def self.default_signer=(default_signer)
        @default_signer = default_signer
      end

      # Passphrase to use to open the private key when signing the file.
      # Default: None.
      def self.default_signer_passphrase=(default_signer_passphrase)
        @default_signer_passphrase = default_signer_passphrase
      end

      # Write to a PGP / GPG file or stream, encrypting the contents as it is written
      #
      # file_name_or_io: [String|IO]
      #   Name of file to write to.
      #   Or, the IO stream to write the encrypted contents to.
      #
      # recipient: [String]
      #   Email of user for which to encypt the file.
      #
      # signer: [String]
      #   Name of user with which to sign the encypted file.
      #   Default: default_signer or do not sign.
      #
      # signer_passphrase: [String]
      #   Passphrase to use to open the private key when signing the file.
      #   Default: default_signer_passphrase
      #
      # binary: [true|false]
      #   Whether to write binary data.
      #   Default: true
      #
      # compression: [:none|:zip|:zlib|:bzip2]
      #   Note: Standard PGP only supports :zip.
      #   :zlib is better than zip.
      #   :bzip2 is best, but uses a lot of memory.
      #   Default: :zip
      #
      # compress_level: [Integer]
      #   Compression level
      #   Default: 6
      def self.open(file_name_or_io, recipient:, signer: default_signer, signer_passphrase: default_signer_passphrase, binary: true, compression: :zip, compress_level: 6)
        compress_level = 0 if compression == :none
        if IOStreams.writer_stream?(file_name_or_io)
          raise(NotImplementedError, 'Can only PGP Encrypt directly to a file name. Output to streams are not yet supported.')
        else
          # Write to stdin, with encrypted contents being written to the file
          cmd = "gpg --batch --no-tty --yes --encrypt"
          cmd << " --sign --local-user \"#{signer}\"" if signer
          cmd << " --passphrase \"#{signer_passphrase}\"" if signer_passphrase
          cmd << " -z #{compress_level}" if compress_level != 6
          cmd << " --compress-algo #{compression}" unless compression == :none
          cmd << " --recipient \"#{recipient}\" -o \"#{file_name_or_io}\""
          Open3.popen2e(cmd) do |stdin, out, waith_thr|
            begin
              stdin.binmode if binary
              yield(stdin)
              stdin.close
            rescue Errno::EPIPE
              # Ignore broken pipe because gpg terminates early due to an error
              ::File.delete(file_name_or_io)
              raise(Pgp::Failure, "GPG Failed writing to encrypted file: #{file_name_or_io}: #{out.read.chomp}")
            end
            unless waith_thr.value.success?
              ::File.delete(file_name_or_io)
              raise(Pgp::Failure, "GPG Failed to create encrypted file: #{file_name_or_io}: #{out.read.chomp}")
            end
          end
        end
      end

      private

      @default_signer_passphrase = nil
      @default_signer            = nil

      def self.default_signer_passphrase
        @default_signer_passphrase
      end

      def self.default_signer
        @default_signer
      end

    end
  end
end
