require "open3"
module IOStreams
  # Read/Write PGP/GPG file or stream.
  #
  # Limitations
  # - Designed for processing larger files since a process is spawned for each file processed.
  # - For small in memory files or individual emails, use the 'opengpgme' library.
  module Pgp
    autoload :Reader, "io_streams/pgp/reader"
    autoload :Writer, "io_streams/pgp/writer"

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

    @executable = "gpg"

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
    def self.generate_key(name:,
                          email:,
                          comment: nil,
                          passphrase:,
                          key_type: "RSA",
                          key_length: 4096,
                          subkey_type: "RSA",
                          subkey_length: key_length,
                          expire_date: nil)
      version_check
      params = ""
      params << "Key-Type: #{key_type}\n" if key_type
      params << "Key-Length: #{key_length}\n" if key_length
      params << "Subkey-Type: #{subkey_type}\n" if subkey_type
      params << "Subkey-Length: #{subkey_length}\n" if subkey_length
      params << "Name-Real: #{name}\n" if name
      params << "Name-Comment: #{comment}\n" if comment
      params << "Name-Email: #{email}\n" if email
      params << "Expire-Date: #{expire_date}\n" if expire_date
      params << "Passphrase: #{passphrase}\n" if passphrase
      params << "%commit"
      command = "#{executable} --batch --gen-key --no-tty"

      out, err, status = Open3.capture3(command, binmode: true, stdin_data: params)
      logger&.debug { "IOStreams::Pgp.generate_key: #{command}\n#{params}\n#{err}#{out}" }

      raise(Pgp::Failure, "GPG Failed to generate key: #{err}#{out}") unless status.success?

      if (match = err.match(/gpg: key ([0-9A-F]+)\s+/))
        match[1]
      end
    end

    # Delete all private and public keys for a particular email.
    #
    # Returns false if no key was found.
    # Raises an exception if it fails to delete the key.
    #
    # email: [String] Optional email address for the key.
    # key_id: [String] Optional id for the key.
    #
    # public: [true|false]
    #   Whether to delete the public key
    #   Default: true
    #
    # private: [true|false]
    #   Whether to delete the private key
    #   Default: false
    def self.delete_keys(email: nil, key_id: nil, public: true, private: false)
      version_check
      method_name = pgp_version.to_f >= 2.2 ? :delete_public_or_private_keys : :delete_public_or_private_keys_v1
      status      = false
      status      = send(method_name, email: email, key_id: key_id, private: true) if private
      status      = send(method_name, email: email, key_id: key_id, private: false) if public
      status
    end

    # Returns [true|false] whether their is a key for the supplied email or key_id
    def self.key?(email: nil, key_id: nil, private: false)
      raise(ArgumentError, "Either :email, or :key_id must be supplied") if email.nil? && key_id.nil?

      !list_keys(email: email, key_id: key_id, private: private).empty?
    end

    # Deprecated
    def self.has_key?(**args)
      key?(**args)
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
      cmd     = private ? "--list-secret-keys" : "--list-keys"
      command = "#{executable} #{cmd} #{email || key_id}"

      out, err, status = Open3.capture3(command, binmode: true)
      logger&.debug { "IOStreams::Pgp.list_keys: #{command}\n#{err}#{out}" }
      if status.success? && out.length.positive?
        parse_list_output(out)
      else
        return [] if err =~ /(not found|No (public|secret) key|key not available)/i

        raise(Pgp::Failure, "GPG Failed calling '#{executable}' to list keys for #{email || key_id}: #{err}#{out}")
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
      command = executable.to_s

      out, err, status = Open3.capture3(command, binmode: true, stdin_data: key)
      logger&.debug { "IOStreams::Pgp.key_info: #{command}\n#{err}#{out}" }

      raise(Pgp::Failure, "GPG Failed extracting key details: #{err} #{out}") unless status.success? && out.length.positive?

      # Sample Output:
      #
      #   pub  4096R/3A5456F5 2017-06-07
      #   uid                            Joe Bloggs <j@bloggs.net>
      #   sub  4096R/2C9B240B 2017-06-07
      parse_list_output(out)
    end

    # Returns [String] containing all the public keys for the supplied email address.
    #
    # email: [String] Email address for requested key.
    #
    # ascii: [true|false]
    #   Whether to export as ASCII text instead of binary format
    #   Default: true
    def self.export(email:, ascii: true, private: false, passphrase: nil)
      version_check

      command = "#{executable} "
      command << "--pinentry-mode loopback " if pgp_version.to_f >= 2.1
      command << "--armor " if ascii
      command << "--no-tty  --batch --passphrase"
      command << (passphrase ? " #{passphrase} " : "-fd 0 ")
      command << (private ? "--export-secret-keys #{email}" : "--export #{email}")

      out, err, status = Open3.capture3(command, binmode: true)
      logger&.debug { "IOStreams::Pgp.export: #{command}\n#{err}" }

      raise(Pgp::Failure, "GPG Failed reading key: #{email}: #{err}") unless status.success? && out.length.positive?

      out
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
      command = "#{executable} --batch --import"

      out, err, status = Open3.capture3(command, binmode: true, stdin_data: key)
      logger&.debug { "IOStreams::Pgp.import: #{command}\n#{err}#{out}" }
      if status.success? && !err.empty?
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

    # Returns [String] email for the supplied after importing and trusting the key
    #
    # Notes:
    # - If the same email address has multiple keys then only the first is currently trusted.
    def self.import_and_trust(key:)
      raise(ArgumentError, "Key cannot be empty") if key.nil? || (key == "")

      key_info = key_info(key: key).last

      email = key_info.fetch(:email, nil)
      key_id = key_info.fetch(:key_id, nil)
      raise(ArgumentError, "Recipient email or key id cannot be extracted from supplied key") unless email || key_id

      import(key: key)
      set_trust(email: email, key_id: key_id)
      email
    end

    # Set the trust level for an existing key.
    #
    # Returns [String] output if the trust was successfully updated
    # Returns nil if the email was not found
    #
    # After importing keys, they are not trusted and the relevant trust level must be set.
    #   Default: 5 : Ultimate
    def self.set_trust(email: nil, key_id: nil, level: 5)
      version_check
      fingerprint = key_id || fingerprint(email: email)
      return unless fingerprint

      command          = "#{executable} --import-ownertrust"
      trust            = "#{fingerprint}:#{level + 1}:\n"
      out, err, status = Open3.capture3(command, stdin_data: trust)
      logger&.debug { "IOStreams::Pgp.set_trust: #{command}\n#{err}#{out}" }

      raise(Pgp::Failure, "GPG Failed trusting key: #{err} #{out}") unless status.success?

      err
    end

    # DEPRECATED - Use key_ids instead of fingerprints
    def self.fingerprint(email:)
      version_check
      Open3.popen2e("#{executable} --list-keys --fingerprint --with-colons #{email}") do |_stdin, out, waith_thr|
        output = out.read.chomp
        unless waith_thr.value.success?
          unless output =~ /(public key not found|No public key)/i
            raise(Pgp::Failure, "GPG Failed calling #{executable} to list keys for #{email}: #{output}")
          end
        end

        output.each_line do |line|
          if (match = line.match(/\Afpr.*::([^\:]*):\Z/))
            return match[1]
          end
        end
        nil
      end
    end

    def self.logger=(logger)
      @logger = logger
    end

    # Returns [String] the version of pgp currently installed
    def self.pgp_version
      @pgp_version ||= begin
        command          = "#{executable} --version"
        out, err, status = Open3.capture3(command)
        logger&.debug { "IOStreams::Pgp.version: #{command}\n#{err}#{out}" }
        if status.success?
          # Sample output
          #   #{executable} (GnuPG) 2.0.30
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
          if (match = out.lines.first.match(/(\d+\.\d+.\d+)/))
            match[1]
          end
        else
          return [] if err =~ /(key not found|No (public|secret) key)/i

          raise(Pgp::Failure, "GPG Failed calling #{executable} to list keys for #{email || key_id}: #{err}#{out}")
        end
      end
    end

    private

    @logger = nil

    def self.logger
      @logger
    end

    def self.version_check
      return unless pgp_version.to_f >= 2.3

      raise(
        Pgp::UnsupportedVersion,
        "Version #{pgp_version} of #{executable} is not yet supported. Please submit a Pull Request to support it."
      )
    end

    # v2.2.1 output:
    #   pub   rsa1024 2017-10-24 [SCEA]
    #   18A0FC1C09C0D8AE34CE659257DC4AE323C7368C
    #   uid           [ultimate] Joe Bloggs <pgp_test@iostreams.net>
    #   sub   rsa1024 2017-10-24 [SEA]
    # v2.0.30 output:
    #   pub   4096R/3A5456F5 2017-06-07
    #   uid       [ unknown] Joe Bloggs <j@bloggs.net>
    #   sub   4096R/2C9B240B 2017-06-07
    # v1.4 output:
    #  sec   2048R/27D2E7FA 2016-10-05
    #  uid                  Receiver <receiver@example.org>
    #  ssb   2048R/893749EA 2016-10-05
    def self.parse_list_output(out)
      results = []
      hash    = {}
      out.each_line do |line|
        if (match = line.match(/(pub|sec)\s+(\D+)(\d+)\s+(\d+-\d+-\d+)\s+(.*)/))
          # v2.2:    pub   rsa1024 2017-10-24 [SCEA]
          hash = {
            private:    match[1] == "sec",
            key_length: match[3].to_s.to_i,
            key_type:   match[2],
            date:       (begin
                           Date.parse(match[4].to_s)
                         rescue StandardError
                           match[4]
                         end)
          }
        elsif (match = line.match(%r{(pub|sec)\s+(\d+)(.*)/(\w+)\s+(\d+-\d+-\d+)(\s+(.+)<(.+)>)?}))
          # Matches: pub  2048R/C7F9D9CB 2016-10-26
          # Or:      pub  2048R/C7F9D9CB 2016-10-26 Receiver <receiver@example.org>
          hash = {
            private:    match[1] == "sec",
            key_length: match[2].to_s.to_i,
            key_type:   match[3],
            key_id:     match[4],
            date:       (begin
                           Date.parse(match[5].to_s)
                         rescue StandardError
                           match[5]
                         end)
          }
          # Prior to gpg v2.0.30
          if match[7]
            hash[:name]  = match[7].strip
            hash[:email] = match[8].strip
            results << hash
            hash = {}
          end
        elsif (match = line.match(/uid\s+(\[(.+)\]\s+)?(.+)<(.+)>/))
          # Matches:  uid       [ unknown] Joe Bloggs <j@bloggs.net>
          # Or:       uid                  Joe Bloggs <j@bloggs.net>
          # v2.2:     uid           [ultimate] Joe Bloggs <pgp_test@iostreams.net>
          hash[:email] = match[4].strip
          hash[:name]  = match[3].to_s.strip
          hash[:trust] = match[2].to_s.strip if match[1]
          results << hash
          hash = {}
        elsif (match = line.match(/uid\s+(\[(.+)\]\s+)?(.+)/))
          # Matches:  uid       [ unknown] Joe Bloggs
          # Or:       uid                  Joe Bloggs
          # v2.2:     uid           [ultimate] Joe Bloggs
          hash[:name]  = match[3].to_s.strip
          hash[:trust] = match[2].to_s.strip if match[1]
          results << hash
          hash = {}
        elsif (match = line.match(/([A-Z0-9]+)/))
          # v2.2  18A0FC1C09C0D8AE34CE659257DC4AE323C7368C
          hash[:key_id] ||= match[1]
        end
      end
      results
    end

    def self.delete_public_or_private_keys(email: nil, key_id: nil, private: false)
      keys = private ? "secret-keys" : "keys"

      list = email ? list_keys(email: email, private: private) : list_keys(key_id: key_id)
      return false if list.empty?

      list.each do |key_info|
        key_id = key_info[:key_id]
        next unless key_id

        command          = "#{executable} --batch --no-tty --yes --delete-#{keys} #{key_id}"
        out, err, status = Open3.capture3(command, binmode: true)
        logger&.debug { "IOStreams::Pgp.delete_keys: #{command}\n#{err}#{out}" }

        unless status.success?
          raise(Pgp::Failure, "GPG Failed calling #{executable} to delete #{keys} for #{email || key_id}: #{err}: #{out}")
        end
        raise(Pgp::Failure, "GPG Failed to delete #{keys} for #{email || key_id} #{err.strip}:#{out}") if out.include?("error")
      end
      true
    end

    def self.delete_public_or_private_keys_v1(email: nil, key_id: nil, private: false)
      keys = private ? "secret-keys" : "keys"

      command = "for i in `#{executable} --list-#{keys} --with-colons --fingerprint #{email || key_id} | grep \"^fpr\" | cut -d: -f10`; do\n"
      command << "#{executable} --batch --no-tty --yes --delete-#{keys} \"$i\" ;\n"
      command << "done"

      out, err, status = Open3.capture3(command, binmode: true)
      logger&.debug { "IOStreams::Pgp.delete_keys: #{command}\n#{err}: #{out}" }

      return false if err =~ /(not found|no public key)/i
      unless status.success?
        raise(Pgp::Failure, "GPG Failed calling #{executable} to delete #{keys} for #{email || key_id}: #{err}: #{out}")
      end
      raise(Pgp::Failure, "GPG Failed to delete #{keys} for #{email || key_id} #{err.strip}: #{out}") if out.include?("error")

      true
    end
  end
end
