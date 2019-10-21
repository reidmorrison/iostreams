require 'open3'

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

        private

        attr_reader :default_signer_passphrase
        attr_reader :default_signer

        @default_signer_passphrase = nil
        @default_signer            = nil
      end

      # Write to a PGP / GPG file, encrypting the contents as it is written.
      #
      # file_name: [String]
      #   Name of file to write to.
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
      # compression: [:none|:zip|:zlib|:bzip2]
      #   Note: Standard PGP only supports :zip.
      #   :zlib is better than zip.
      #   :bzip2 is best, but uses a lot of memory and is much slower.
      #   Default: :zip
      #
      # compress_level: [Integer]
      #   Compression level
      #   Default: 6
      def self.file(file_name, recipient: nil, import_and_trust_key: nil, signer: default_signer, signer_passphrase: default_signer_passphrase, compression: :zip, compress_level: 6, original_file_name: nil)
        raise(ArgumentError, "Either :recipient or :import_and_trust_key") unless recipient || import_and_trust_key

        recipient      = IOStreams::Pgp.import_and_trust(key: import_and_trust_key) if import_and_trust_key
        compress_level = 0 if compression == :none

        # Write to stdin, with encrypted contents being written to the file
        command = "#{IOStreams::Pgp.executable} --batch --no-tty --yes --encrypt"
        command << " --sign --local-user \"#{signer}\"" if signer
        if signer_passphrase
          command << " --pinentry-mode loopback" if IOStreams::Pgp.pgp_version.to_f >= 2.1
          command << " --passphrase \"#{signer_passphrase}\""
        end
        command << " -z #{compress_level}" if compress_level != 6
        command << " --compress-algo #{compression}" unless compression == :none
        command << " --recipient \"#{recipient}\" -o \"#{file_name}\""

        IOStreams::Pgp.logger&.debug { "IOStreams::Pgp::Writer.open: #{command}" }

        Open3.popen2e(command) do |stdin, out, waith_thr|
          begin
            stdin.binmode
            yield(stdin)
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
      end

    end
  end
end
