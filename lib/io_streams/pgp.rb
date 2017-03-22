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
  #
  # Compression Performance:
  #   Running tests on an Early 2015 Macbook Pro Dual Core with Ruby v2.3.1
  #
  #   Input file: test.log 3.6GB
  #     :none:  size: 3.6GB  write:  52s  read:  45s
  #     :zip:   size: 411MB  write:  75s  read:  31s
  #     :zlib:  size: 241MB  write:  66s  read:  23s  ( 756KB Memory )
  #     :bzip2: size: 129MB  write: 430s  read: 130s  ( 5MB Memory )
  module Pgp
    autoload :Reader, 'io_streams/pgp/reader'
    autoload :Writer, 'io_streams/pgp/writer'

    class Failure < StandardError
    end

    # Generate a new ultimate trusted local public and private key
    # Returns [String] the key id for the generated key
    # Raises an exception if it fails to generate the key
    #
    # name: [String]
    #   Name of who owns the key, such as organization
    #
    # email: [String]
    #   Email address for the key
    #
    # comment: [String]
    #   Optional comment to add to the generated key
    #
    # passphrase [String]
    #   Optional passphrase to secure the key with.
    #   Highly Recommended.
    #   To generate a good passphrase:
    #     `SecureRandom.urlsafe_base64(128)`
    #
    # See `man gpg` for the remaining options
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
    #
    # email: [String] Email address for the key
    #
    # public: [true|false]
    #   Whether to delete the public key
    #   Default: true
    #
    # secret: [true|false]
    #   Whether to delete the secret key
    #   Default: false
    def self.delete_keys(email:, public: true, secret: false)
      cmd = "for i in `gpg --with-colons --fingerprint #{email} | grep \"^fpr\" | cut -d: -f10`; do\n"
      cmd << "gpg --batch --delete-secret-keys \"$i\" ;\n" if secret
      cmd << "gpg --batch --delete-keys \"$i\" ;\n" if public
      cmd << 'done'
      Open3.popen2e(cmd) do |stdin, out, waith_thr|
        output = out.read.chomp
        if waith_thr.value.success?
          return false if output =~ /(public key not found|No public key)/i
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
            return true if line.include?(email)
          end
          false
        else
          return false if output =~ /(public key not found|No public key)/i
          raise(Pgp::Failure, "GPG Failed calling gpg to list keys for #{email}: #{output}")
        end
      end
    end

    # Returns [String] the first fingerprint for the supplied email
    # Returns nil if no fingerprint was found
    def self.fingerprint(email:)
      Open3.popen2e("gpg --list-keys --fingerprint --with-colons #{email}") do |stdin, out, waith_thr|
        output = out.read.chomp
        if waith_thr.value.success?
          output.each_line do |line|
            if match = line.match(/\Afpr.*::([^\:]*):\Z/)
              return match[1]
            end
          end
          nil
        else
          return if output =~ /(public key not found|No public key)/i
          raise(Pgp::Failure, "GPG Failed calling gpg to list keys for #{email}: #{output}")
        end
      end
    end

    # Returns [String] the key for the supplied email address
    #
    # email: [String] Email address for requested key
    #
    # ascii: [true|false]
    #   Whether to export as ASCII text instead of binary format
    #   Default: true
    #
    # secret: [true|false]
    #   Whether to export the private key
    #   Default: false
    def self.export(email:, ascii: true, secret: false)
      armor            = ascii ? ' --armor' : nil
      cmd              = secret ? '--export-secret-keys' : '--export'
      out, err, status = Open3.capture3("gpg#{armor} #{cmd} #{email}", binmode: true)
      if status.success? && out.length > 0
        out
      else
        raise(Pgp::Failure, "GPG Failed reading key: #{email}: #{err} #{out}")
      end
    end

    # Imports the supplied public/private key
    # Returns [String] the output returned from the import command
    def self.import(key)
      out, err, status = Open3.capture3('gpg --import', binmode: true, stdin_data: key)
      if status.success? && out.length > 0
        out
      else
        raise(Pgp::Failure, "GPG Failed importing key: #{err} #{out}")
      end
    end

    # Set the trust level for an existing key.
    #
    # Returns [String] output if the trust was successfully updated
    # Returns nil if the email was not found
    #
    # After importing keys, they are not trusted and the relevant trust level must be set.
    #   Default: 5 : Ultimate
    def self.set_trust(email:, level: 5)
      fingerprint = fingerprint(email: email)
      return unless fingerprint

      trust            = "#{fingerprint}:#{level + 1}:\n"
      out, err, status = Open3.capture3('gpg --import-ownertrust', stdin_data: trust)
      if status.success?
        err
      else
        raise(Pgp::Failure, "GPG Failed trusting key: #{err} #{out}")
      end
    end

  end
end
