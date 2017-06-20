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
  #       p stream.read(10)
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
  #       p data
  #     end
  #   end
  #
  # FAQ:
  # - If you get not trusted errors
  #    gpg --edit-key sender@example.org
  #      Select highest level: 5
  #
  # Delete test keys:
  #   IOStreams::Pgp.delete_keys(email: 'sender@example.org', private: true)
  #   IOStreams::Pgp.delete_keys(email: 'receiver@example.org', private: true)
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
  #
  # Notes:
  # - Tested against gnupg v1.4.21 and v2.0.30
  # - Does not work yet with gnupg v2.1. Pull Requests welcome.
  module Pgp
    autoload :Reader, 'io_streams/pgp/reader'
    autoload :Writer, 'io_streams/pgp/writer'

    class Failure < StandardError
    end

    class UnsupportedVersion < Failure
    end

    def self.executable
      @executable
    end

    def self.executable=(executable)
      @executable = executable
    end

    @executable = 'gpg'

    # Generate a new ultimate trusted local public and private key.
    #
    # Returns [String] the key id for the generated key.
    # Raises an exception if it fails to generate the key.
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
      version_check
      params = ''
      params << "Key-Type: #{key_type}\n" if key_type
      params << "Key-Length: #{key_length}\n" if key_length
      params << "Subkey-Type: #{subkey_type}\n" if subkey_type
      params << "Subkey-Length: #{subkey_length}\n" if subkey_length
      params << "Name-Real: #{name}\n" if name
      params << "Name-Comment: #{comment}\n" if comment
      params << "Name-Email: #{email}\n" if email
      params << "Expire-Date: #{expire_date}\n" if expire_date
      params << "Passphrase: #{passphrase}\n" if passphrase
      params << '%commit'
      out, err, status = Open3.capture3("#{executable} --batch --gen-key", binmode: true, stdin_data: params)
      logger.debug { "IOStreams::Pgp.generate_key output:\n#{out}#{err}" } if logger
      if status.success?
        if match = err.match(/gpg: key ([0-9A-F]+)\s+/)
          return match[1]
        end
      else
        raise(Pgp::Failure, "GPG Failed to generate key: #{out}#{err}")
      end
    end

    # Delete all private and public keys for a particular email.
    #
    # Returns false if no key was found.
    # Raises an exception if it fails to delete the key.
    #
    # email: [String] Email address for the key.
    #
    # public: [true|false]
    #   Whether to delete the public key
    #   Default: true
    #
    # private: [true|false]
    #   Whether to delete the private key
    #   Default: false
    def self.delete_keys(email:, public: true, private: false)
      version_check
      cmd = "for i in `gpg --with-colons --fingerprint #{email} | grep \"^fpr\" | cut -d: -f10`; do\n"
      cmd << "#{executable} --batch --delete-secret-keys \"$i\" ;\n" if private
      cmd << "#{executable} --batch --delete-keys \"$i\" ;\n" if public
      cmd << 'done'

      out, err, status = Open3.capture3(cmd, binmode: true)
      logger.debug { "IOStreams::Pgp.delete_keys output:\n#{err}#{out}" } if logger

      if status.success?
        return false if err =~ /(not found|No public key)/i
        raise(Pgp::Failure, "GPG Failed to delete keys for #{email}:#{err}#{out}") if out.include?('error')
        true
      else
        raise(Pgp::Failure, "GPG Failed calling gpg to delete private keys for #{email}: #{err}#{out}")
      end
    end

    # Returns [true|false] whether their is a key for the supplied email or key_id
    def self.has_key?(email: nil, key_id: nil, private: false)
      raise(ArgumentError, 'Either :email, or :key_id must be supplied') if email.nil? && key_id.nil?

      !list_keys(email: email, key_id: key_id, private: private).empty?
    end

    # Returns [Array<Hash>] the list of keys.
    #   Each Hash consists of:
    #     key_length: [Integer]
    #     key_type:   [String]
    #     key_id:     [String]
    #     date:       [String]
    #     name:       [String]
    #     email:      [String]
    # Returns [] if no keys were found.
    def self.list_keys(email: nil, key_id: nil, private: false)
      version_check
      cmd              = private ? '--list-secret-keys' : '--list-keys'
      out, err, status = Open3.capture3("#{executable} #{cmd} #{email || key_id}", binmode: true)
      logger.debug { "IOStreams::Pgp.list_keys output:\n#{err}#{out}" } if logger
      if status.success? && out.length > 0
        # v2.0.30 output:
        #   pub   4096R/3A5456F5 2017-06-07
        #   uid       [ unknown] Joe Bloggs <j@bloggs.net>
        #   sub   4096R/2C9B240B 2017-06-07
        # v1.4 output:
        #  sec   2048R/27D2E7FA 2016-10-05
        #  uid                  Receiver <receiver@example.org>
        #  ssb   2048R/893749EA 2016-10-05
        parse_list_output(out)
      else
        return [] if err =~ /(key not found|No (public|secret) key|key not available)/i
        raise(Pgp::Failure, "GPG Failed calling gpg to list keys for #{email || key_id}: #{err}#{out}")
      end
    end

    # Extract information from the supplied key.
    #
    # Useful for confirming encryption keys before importing them.
    #
    # Returns [Array<Hash>] the list of primary keys.
    #   Each Hash consists of:
    #     key_length: [Integer]
    #     key_type:   [String]
    #     key_id:     [String]
    #     date:       [String]
    #     name:       [String]
    #     email:      [String]
    def self.key_info(key:)
      version_check
      out, err, status = Open3.capture3(executable, binmode: true, stdin_data: key)
      logger.debug { "IOStreams::Pgp.key_info output:\n#{err}#{out}" } if logger
      if status.success? && out.length > 0
        # Sample Output:
        #
        #   pub  4096R/3A5456F5 2017-06-07
        #   uid                            Joe Bloggs <j@bloggs.net>
        #   sub  4096R/2C9B240B 2017-06-07
        parse_list_output(out)
      else
        raise(Pgp::Failure, "GPG Failed extracting key details: #{err} #{out}")
      end
    end

    # Returns [String] containing all the keys for the supplied email address.
    #
    # email: [String] Email address for requested key.
    #
    # ascii: [true|false]
    #   Whether to export as ASCII text instead of binary format
    #   Default: true
    #
    # private: [true|false]
    #   Whether to export the private key
    #   Default: false
    def self.export(email:, ascii: true, private: false)
      version_check
      armor            = ascii ? '--armor' : nil
      cmd              = private ? '--export-secret-keys' : '--export'
      out, err, status = Open3.capture3("#{executable} #{armor} #{cmd} #{email}", binmode: true)
      logger.debug { "IOStreams::Pgp.export output:\n#{err}" } if logger
      if status.success? && out.length > 0
        out
      else
        raise(Pgp::Failure, "GPG Failed reading key: #{email}: #{err}")
      end
    end

    # Imports the supplied public/private key
    #
    # Returns [Array<Hash>] keys that were successfully imported.
    #   Each Hash consists of:
    #     key_id: [String]
    #     type:   [String]
    #     name:   [String]
    #     email:  [String]
    # Returns [] if the same key was previously imported.
    #
    # Raises Pgp::Failure if there was an issue importing any of the keys.
    #
    # Notes:
    # * Importing a new key for the same email address does not remove the prior key if any.
    # * Invalidated keys must be removed manually.
    def self.import(key:)
      version_check
      out, err, status = Open3.capture3("#{executable} --import", binmode: true, stdin_data: key)
      logger.debug { "IOStreams::Pgp.import output:\n#{err}#{out}" } if logger
      if status.success? && err.length > 0
        # Sample output
        #
        #   gpg: key C16500E3: secret key imported\n"
        #   gpg: key C16500E3: public key "Joe Bloggs <pgp_test@iostreams.net>" imported
        #   gpg: Total number processed: 1
        #   gpg:               imported: 1  (RSA: 1)
        #   gpg:       secret keys read: 1
        #   gpg:   secret keys imported: 1
        #
        # Ignores unchanged:
        #   gpg: key 9615D46D: \"Joe Bloggs <j@bloggs.net>\" not changed\n
        results = []
        secret  = false
        err.each_line do |line|
          if line =~ /secret key imported/
            secret = true
          elsif match = line.match(/key\s+(\w+):\s+(\w+).+\"(.*)<(.*)>\"/)
            results << {
              key_id:  match[1].to_s.strip,
              private: secret,
              name:    match[3].to_s.strip,
              email:   match[4].to_s.strip
            }
            secret = false
          end
        end
        results
      else
        return [] if err =~ /already in secret keyring/
        raise(Pgp::Failure, "GPG Failed importing key: #{err}#{out}")
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
      version_check
      fingerprint = fingerprint(email: email)
      return unless fingerprint

      trust            = "#{fingerprint}:#{level + 1}:\n"
      out, err, status = Open3.capture3("#{executable} --import-ownertrust", stdin_data: trust)
      logger.debug { "IOStreams::Pgp.set_trust output:\n#{err}#{out}" } if logger
      if status.success?
        err
      else
        raise(Pgp::Failure, "GPG Failed trusting key: #{err} #{out}")
      end
    end

    # DEPRECATED - Use key_ids instead of fingerprints
    def self.fingerprint(email:)
      version_check
      Open3.popen2e("#{executable} --list-keys --fingerprint --with-colons #{email}") do |stdin, out, waith_thr|
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

    def self.logger=(logger)
      @logger = logger
    end

    # Returns [String] the version of pgp currently installed
    def self.pgp_version
      @pgp_version ||= begin
        out, err, status = Open3.capture3("#{executable} --version")
        logger.debug { "IOStreams::Pgp.version output:\n#{err}#{out}" } if logger
        if status.success?
          # Sample output
          #   gpg (GnuPG) 2.0.30
          #   libgcrypt 1.7.6
          #   Copyright (C) 2015 Free Software Foundation, Inc.
          #   License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
          #   This is free software: you are free to change and redistribute it.
          #   There is NO WARRANTY, to the extent permitted by law.
          #
          #   Home: ~/.gnupg
          #   Supported algorithms:
          #   Pubkey: RSA, RSA, RSA, ELG, DSA
          #   Cipher: IDEA, 3DES, CAST5, BLOWFISH, AES, AES192, AES256, TWOFISH,
          #           CAMELLIA128, CAMELLIA192, CAMELLIA256
          #   Hash: MD5, SHA1, RIPEMD160, SHA256, SHA384, SHA512, SHA224
          #   Compression: Uncompressed, ZIP, ZLIB, BZIP2
          if match = out.lines.first.match(/(\d+\.\d+.\d+)/)
            match[1]
          end
        else
          return [] if err =~ /(key not found|No (public|secret) key)/i
          raise(Pgp::Failure, "GPG Failed calling gpg to list keys for #{email || key_id}: #{err}#{out}")
        end
      end
    end

    private

    @logger = nil

    def self.logger
      @logger
    end

    def self.version_check
      raise(Pgp::UnsupportedVersion, "Version #{pgp_version} of gpg is not yet supported. You are welcome to submit a Pull Request.") if pgp_version.to_f >= 2.1
    end

    def self.parse_list_output(out)
      results = []
      hash    = {}
      out.each_line do |line|
        if match = line.match(/(pub|sec)\s+(\d+)(.*)\/(\w+)\s+(\d+-\d+-\d+)(\s+(.+)<(.+)>)?/)
          # Matches: pub  2048R/C7F9D9CB 2016-10-26
          # Or:      pub  2048R/C7F9D9CB 2016-10-26 Receiver <receiver@example.org>
          hash = {
            private:    match[1] == 'sec',
            key_length: match[2].to_s.to_i,
            key_type:   match[3],
            key_id:     match[4],
            date:       (Date.parse(match[5].to_s) rescue match[5])
          }
          # Prior to gpg v2.0.30
          if match[7]
            hash[:name]  = match[7].strip
            hash[:email] = match[8].strip
            results << hash
            hash = {}
          end
        elsif match = line.match(/uid\s+(\[(.+)\]\s+)?(.+)<(.+)>/)
          # Matches:  uid       [ unknown] Joe Bloggs <j@bloggs.net>
          # Or:       uid                  Joe Bloggs <j@bloggs.net>
          hash[:email] = match[4].strip
          hash[:name]  = match[3].to_s.strip
          hash[:trust] = match[2].to_s.strip if match[1]
          results << hash
          hash = {}
        end

      end
      results
    end

  end
end
