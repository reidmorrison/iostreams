require 'open3'
module IOStreams
  # Read/Write PGP/GPG file or stream.
  #
  # Example Setup:
  #
  #   1. Install OpenPGP
  #      Mac OSX (homebrew) : `brew install gpg2`
  #      Redhat Linux: `rpm install gpg2`
  #
  #   2. # Generate senders private and public key
  #      IOStreams::Pgp.generate_key(name: 'Sender', email: 'sender@example.org', passphrase: 'sender_passphrase')
  #
  #   3. # Generate receivers private and public key
  #      IOStreams::Pgp.generate_key(name: 'Receiver', email: 'receiver@example.org', passphrase: 'receiver_passphrase')
  #
  # Example 1:
  #
  #   # Generate encrypted file for a specific recipient and sign it with senders credentials
  #   data = %w(this is some data that should be encrypted using pgp)
  #   IOStreams::Pgp::Writer.open('secure.gpg', recipient: 'receiver@example.org', signer: 'sender@example.org', signer_passphrase: 'sender_passphrase') do |output|
  #     data.each { |word| output.puts(word) }
  #   end
  #
  #   # Decrypt the file sent to `receiver@example.org` using its private key
  #   # Recipient must also have the senders public key to verify the signature
  #   IOStreams::Pgp::Reader.open('secure.gpg', passphrase: 'receiver_passphrase') do |stream|
  #     while !stream.eof?
  #       ap stream.read(10)
  #       puts
  #     end
  #   end
  #
  # Example 2:
  #
  #   # Default user and passphrase to sign the output file:
  #   IOStreams::Pgp::Writer.default_signer            = 'sender@example.org'
  #   IOStreams::Pgp::Writer.default_signer_passphrase = 'sender_passphrase'
  #
  #   # Default passphrase for decrypting recipients files.
  #   # Note: Usually this would be the senders passphrase, but in this example
  #   #       it is decrypting the file intended for the recipient.
  #   IOStreams::Pgp::Reader.default_passphrase = 'receiver_passphrase'
  #
  #   # Generate encrypted file for a specific recipient and sign it with senders credentials
  #   data = %w(this is some data that should be encrypted using pgp)
  #   IOStreams.writer('secure.gpg', pgp: {recipient: 'receiver@example.org'}) do |output|
  #     data.each { |word| output.puts(word) }
  #   end
  #
  #   # Decrypt the file sent to `receiver@example.org` using its private key
  #   # Recipient must also have the senders public key to verify the signature
  #   IOStreams.reader('secure.gpg') do |stream|
  #     while data = stream.read(10)
  #       ap data
  #     end
  #   end
  #
  # FAQ:
  # - If you get not trusted errors
  #    gpg --edit-key sender@example.org
  #      Select highest level: 5
  #
  # Delete test keys:
  #   IOStreams::Pgp.delete_keys(email: 'sender@example.org', secret: true)
  #   IOStreams::Pgp.delete_keys(email: 'receiver@example.org', secret: true)
  #
  # Limitations
  # - Designed for processing larger files since a process is spawned for each file processed.
  # - For small in memory files or individual emails, use the 'opengpgme' library.
  module Pgp
    autoload :Reader, 'io_streams/pgp/reader'
    autoload :Writer, 'io_streams/pgp/writer'

    class Failure < StandardError
    end

    # Generate a new ultimate trusted local public and private key
    # Returns [String] the key id for the generated key
    # Raises an exception if it fails to generate the key
    def self.generate_key(name:, email:, comment: nil, passphrase: nil, key_type: 'RSA', key_length: 4096, subkey_type: 'RSA', subkey_length: key_length, expire_date: nil)
      Open3.popen2e('gpg --batch --gen-key') do |stdin, out, waith_thr|
        stdin.puts "Key-Type: #{key_type}" if key_type
        stdin.puts "Key-Length: #{key_length}" if key_length
        stdin.puts "Subkey-Type: #{subkey_type}" if subkey_type
        stdin.puts "Subkey-Length: #{subkey_length}" if subkey_length
        stdin.puts "Name-Real: #{name}" if name
        stdin.puts "Name-Comment: #{comment}" if comment
        stdin.puts "Name-Email: #{email}" if email
        stdin.puts "Expire-Date: #{expire_date}" if expire_date
        stdin.puts "Passphrase: #{passphrase}" if passphrase
        stdin.puts '%commit'
        stdin.close
        if waith_thr.value.success?
          key_id = nil
          out.each_line do |line|
            if (line = line.chomp) =~ /^gpg: key ([0-9A-F]+) marked as ultimately trusted/
              key_id = $1.to_i(16)
            end
          end
          key_id
        else
          raise(Pgp::Failure, "GPG Failed to generate key: #{out.read.chomp}")
        end
      end
    end

    # Delete a secret and public keys using its email
    # Returns false if no key was found
    # Raises an exception if it fails to delete the key
    def self.delete_keys(email:, secret: false, public: true)
      cmd = "for i in `gpg --with-colons --fingerprint #{email} | grep \"^fpr\" | cut -d: -f10`; do\n"
      cmd << "gpg --batch --delete-secret-keys \"$i\" ;\n" if secret
      cmd << "gpg --batch --delete-keys \"$i\" ;\n" if public
      cmd << 'done'
      Open3.popen2e(cmd) do |stdin, out, waith_thr|
        output = out.read.chomp
        if waith_thr.value.success?
          return false if output.downcase.include?('no public key')
          raise(Pgp::Failure, "GPG Failed to delete keys for #{email}: #{output}") if output.include?('error')
          true
        else
          raise(Pgp::Failure, "GPG Failed calling gpg to delete secret keys for #{email}: #{output}")
        end
      end
    end

    def self.has_key?(email:)
      Open3.popen2e("gpg --list-keys --with-colons #{email}") do |stdin, out, waith_thr|
        output = out.read.chomp
        if waith_thr.value.success?
          output.each_line do |line|
            return true if line.match(/\Auid.*::([^\:]*):\Z/)
          end
          false
        else
          return false if output.downcase.include?('no public key')
          raise(Pgp::Failure, "GPG Failed calling gpg to list keys for #{email}: #{output}")
        end
      end
    end

  end
end
