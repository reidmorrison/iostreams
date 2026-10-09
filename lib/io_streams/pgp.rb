require "open3"
require "shellwords"
module IOStreams
  # Read/Write PGP/GPG file or stream.
  #
  # Limitations
  # - Designed for processing larger files since a process is spawned for each file processed.
  # - For small in memory files or individual emails, use the 'opengpgme' library.
  module Pgp
    extend StreamFormat

    autoload :GpgProcess, "io_streams/pgp/gpg_process"
    autoload :Reader, "io_streams/pgp/reader"
    autoload :Writer, "io_streams/pgp/writer"

    # Returns [Class] the class that decrypts.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that encrypts.
    def self.writer_class
      Writer
    end

    # Returns [true|false] whether data in this format is compressed: false, since compression within an
    # encrypted file is optional, and only the file records whether it was used.
    def self.compressed?
      false
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      true
    end

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

    # Returns [Array<String>] the argv used to invoke gpg, with the supplied
    # arguments appended.
    #
    # All gpg invocations are run without a shell (the multi-argument form of
    # `Open3`) so that values such as email addresses, key ids, passphrases and
    # file names cannot be interpreted as shell commands. The configured
    # `executable` is split with `Shellwords` so that it may still contain
    # additional fixed arguments (for example "gpg --homedir /path").
    def self.gpg_command(*args)
      Shellwords.split(executable) + args.map(&:to_s)
    end

    # Returns [String] the supplied email address or key id, in the form that gpg uses to find the key.
    #
    # gpg treats a bare email address as a case-insensitive search for any user id containing it, so that
    # `bob@example.com` also finds `jimbob@example.com` and `bob@example.com.attacker.net`. Enclosing an
    # email address in `<` and `>` only finds keys with exactly that email address, ignoring case.
    # Anything else, such as a key id, fingerprint, name, an email address already in `<` and `>`, or a value
    # that starts with one of gpg's search prefixes, such as `*` for a substring search, is returned unchanged.
    #
    # Used internally, including by the PGP writer.
    def self.user_id(value)
      value = value.to_s
      value.match?(/\A[^<>@\s*=&+#^][^<>@\s]*@[^<>@\s]+\z/) ? "<#{value}>" : value
    end

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
    #   Pass `nil` to generate an unprotected (passphrase-less) key.
    #
    # key_curve / subkey_curve [String]
    #   Optional Elliptic Curve to use for the (sub)key, e.g. "ed25519".
    #   When supplied the corresponding key/subkey length is ignored.
    #   Requires GnuPG 2.1 or later.
    #
    # key_usage / subkey_usage [String]
    #   Optional comma separated list of (sub)key capabilities, e.g. "sign".
    #   Requires GnuPG 2.1 or later.
    #
    # creation_date [String]
    #   Optional creation date for the key, e.g. "20240101T000000".
    #   Requires GnuPG 2.1 or later.
    #
    # See `man gpg` for the remaining options
    def self.generate_key(name:,
                          email:,
                          passphrase:,
                          comment: nil,
                          key_type: "RSA",
                          key_length: 4096,
                          subkey_type: "RSA",
                          subkey_length: key_length,
                          key_curve: nil,
                          key_usage: nil,
                          subkey_curve: nil,
                          subkey_usage: nil,
                          creation_date: nil,
                          expire_date: nil)
      version_check

      # Reject newlines so that a value cannot inject additional directives into
      # the gpg batch key-generation parameter file.
      reject_newlines!(name: name, email: email, comment: comment, passphrase: passphrase,
                       key_type: key_type, subkey_type: subkey_type, expire_date: expire_date,
                       key_curve: key_curve, key_usage: key_usage,
                       subkey_curve: subkey_curve, subkey_usage: subkey_usage,
                       creation_date: creation_date)

      # `%no-protection`, and the Elliptic Curve / usage / creation-date directives
      # were all introduced in GnuPG 2.1. Keep older versions working by only
      # emitting them when a 2.1+ binary is detected. `--batch --gen-key` accepts
      # all of these on 2.1+, so there is no need for the newer `--full-gen-key`.
      modern = version_at_least?("2.1")

      unless modern
        new_options = {
          key_curve:     key_curve,
          key_usage:     key_usage,
          subkey_curve:  subkey_curve,
          subkey_usage:  subkey_usage,
          creation_date: creation_date
        }.compact
        unless new_options.empty?
          raise(ArgumentError,
                "IOStreams::Pgp.generate_key: #{new_options.keys.join(', ')} require GnuPG 2.1 or later " \
                "(detected #{pgp_version})")
        end
      end

      params = +""
      # `%no-protection` is a control statement and must precede the key parameters.
      # GnuPG 2.1+ requires this explicit opt-out to create an unprotected key;
      # older versions create one simply by omitting the Passphrase directive.
      params << "%no-protection\n" if !passphrase && modern
      params << "Key-Type: #{key_type}\n" if key_type
      # Key-Length and Key-Curve are mutually exclusive: curves imply their own length.
      params << "Key-Length: #{key_length}\n" if key_length && !key_curve
      params << "Key-Curve: #{key_curve}\n" if key_curve
      params << "Key-Usage: #{key_usage}\n" if key_usage
      params << "Subkey-Type: #{subkey_type}\n" if subkey_type
      params << "Subkey-Length: #{subkey_length}\n" if subkey_length && !subkey_curve
      params << "Subkey-Curve: #{subkey_curve}\n" if subkey_curve
      params << "Subkey-Usage: #{subkey_usage}\n" if subkey_usage
      params << "Name-Real: #{name}\n" if name
      params << "Name-Comment: #{comment}\n" if comment
      params << "Name-Email: #{email}\n" if email
      params << "Expire-Date: #{expire_date}\n" if expire_date
      params << "Creation-Date: #{creation_date}\n" if creation_date
      params << "Passphrase: #{passphrase}\n" if passphrase
      params << "%commit"

      args       = ["--batch", "--no-tty"]
      stdin_data = params
      # Signing the subkey binding unlocks the new key. Without loopback, gpg-agent asks pinentry
      # for the passphrase whenever it no longer has it cached, which fails without a tty.
      # So supply it on the first line of stdin, ahead of the parameters.
      if modern
        args += ["--pinentry-mode", "loopback"]
        if passphrase
          args += ["--passphrase-fd", "0"]
          stdin_data = "#{passphrase}\n#{params}"
        end
      end
      args << "--gen-key"
      command = gpg_command(*args)

      out, err, status = Open3.capture3(*command, binmode: true, stdin_data: stdin_data)
      # Do not log `params`, it contains the passphrase.
      IOStreams.logger&.debug { "IOStreams::Pgp.generate_key: #{command.shelljoin}\n#{err}#{out}" }

      raise(Pgp::Failure, "GPG Failed to generate key: #{err}#{out}") unless status.success?

      # Match different output formats for various GPG versions
      if (match = err.match(/gpg: key ([0-9A-F]+)\s+/))
        match[1]
      # For GPG 2.4+
      elsif (match = err.match(/gpg: revocation certificate stored as.*\n.*([0-9A-F]+)/))
        match[1]
      # Match new format for GnuPG 2.4.x
      elsif (match = err.match(/([0-9A-F]+)\.rev/i))
        match[1]
      end
    end

    # Delete all private and public keys for a particular email or key id.
    #
    # Returns false if no key was found.
    # Raises an exception if it fails to delete the key.
    # Raises ArgumentError when neither :email nor :key_id is supplied.
    #
    # email: [String] Email address for the key.
    # key_id: [String] Id for the key.
    #
    # public: [true|false]
    #   Whether to delete the public key
    #   Default: true
    #
    # private: [true|false]
    #   Whether to delete the private key
    #   Default: false
    def self.delete_keys(email: nil, key_id: nil, public: true, private: false)
      raise(ArgumentError, "Either :email, or :key_id must be supplied") if email.nil? && key_id.nil?

      version_check
      # Version 2.1+ uses delete_public_or_private_keys
      # Version < 2.1 uses delete_public_or_private_keys_v1
      method_name = version_at_least?("2.1") ? :delete_public_or_private_keys : :delete_public_or_private_keys_v1
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

    # Returns [Array<Hash>] the list of keys.
    #   Each Hash consists of:
    #     key_length: [Integer]
    #     key_type:   [String]
    #     key_id:     [String]
    #     date:       [String]
    #     name:       [String]
    #     email:      [String]
    #     private:    [true|false]
    #     trust:      [String]
    # Returns [] if no keys were found.
    def self.list_keys(email: nil, key_id: nil, private: false)
      version_check
      args = [private ? "--list-secret-keys" : "--list-keys"]
      # `--` stops gpg from treating the email or key id as an option.
      args += ["--", user_id(email || key_id)] if email || key_id
      command = gpg_command(*args)

      out, err, status = Open3.capture3(*command, binmode: true)
      IOStreams.logger&.debug { "IOStreams::Pgp.list_keys: #{command.shelljoin}\n#{err}#{out}" }
      if status.success?
        # An empty keyring lists nothing.
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
    #     private:    [true|false]
    #     trust:      [String]
    def self.key_info(key:)
      version_check
      command = gpg_command("--batch", "--no-tty")

      out, err, status = Open3.capture3(*command, binmode: true, stdin_data: key)
      IOStreams.logger&.debug { "IOStreams::Pgp.key_info: #{command.shelljoin}\n#{err}#{out}" }

      # Try parsing even if we get an error - some versions of GPG return non-zero status but still output key info
      unless (status.success? || err.include?("key ID") || out.include?("pub")) && out.length.positive?
        raise(Pgp::Failure, "GPG Failed extracting key details: #{err} #{out}")
      end

      # Sample Output:
      #
      #   pub  4096R/3A5456F5 2017-06-07
      #   uid                            Joe Bloggs <j@bloggs.net>
      #   sub  4096R/2C9B240B 2017-06-07
      parse_list_output(out)
    end

    # Returns [String] containing all the public keys for the supplied email address or key id.
    #
    # Raises ArgumentError when neither :email nor :key_id is supplied.
    #
    # email: [String] Email address for requested key.
    #
    # key_id: [String] Id for the requested key.
    #
    # ascii: [true|false]
    #   Whether to export as ASCII text instead of binary format
    #   Default: true
    def self.export(email: nil, key_id: nil, ascii: true, private: false, passphrase: nil)
      raise(ArgumentError, "Either :email, or :key_id must be supplied") if email.nil? && key_id.nil?

      version_check

      args = passphrase_args
      args << "--armor" if ascii
      args += ["--no-tty", "--batch"]
      # Supply the passphrase on stdin so that it is not visible in the process list.
      args += ["--passphrase-fd", "0"]
      args << (private ? "--export-secret-keys" : "--export")
      args += ["--", user_id(email || key_id)]
      command = gpg_command(*args)

      out, err, status = Open3.capture3(*command, binmode: true, stdin_data: passphrase.to_s)
      IOStreams.logger&.debug { "IOStreams::Pgp.export: #{command.shelljoin}\n#{err}" }

      raise(Pgp::Failure, "GPG Failed reading key: #{email || key_id}: #{err}") unless status.success? && out.length.positive?

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
      command = gpg_command("--batch", "--import")

      out, err, status = Open3.capture3(*command, binmode: true, stdin_data: key)
      IOStreams.logger&.debug { "IOStreams::Pgp.import: #{command.shelljoin}\n#{err}#{out}" }

      # Handle both old and new versions of GPG
      # For older versions, the output is in err, for newer ones it might be in out
      output = err.empty? ? out : err

      # Check for duplicate keys or "not changed" messages
      return [] if output =~ /already in secret keyring/i || output =~ /not changed/i

      # Check for successful import in output, even if status has warnings
      import_successful = status.success? || output =~ /imported:\s*\d+/i || output =~ /public key.*imported/i

      if import_successful && !output.empty?
        # Sample output for GnuPG < 2.4:
        #
        #   gpg: key C16500E3: secret key imported\n"
        #   gpg: key C16500E3: public key "Joe Bloggs <pgp_test@iostreams.net>" imported
        #   gpg: Total number processed: 1
        #   gpg:               imported: 1  (RSA: 1)
        #   gpg:       secret keys read: 1
        #   gpg:   secret keys imported: 1
        #
        # Sample output for GnuPG >= 2.4:
        #   gpg: key 7932AB23D7238F6B: public key "Joe Bloggs <j@bloggs.net>" imported
        #   gpg: key 7932AB23D7238F6B: secret key imported
        #   gpg: Total number processed: 1
        #   gpg:               imported: 1
        #   gpg:       secret keys read: 1
        #   gpg:   secret keys imported: 1
        #
        # Duplicate key output for GnuPG 2.4:
        #   gpg: key 9DAB25FCEE68318A: "Joe Bloggs <pgp_test@iostreams.net>" not changed
        #   gpg: Total number processed: 1
        #   gpg:              unchanged: 1
        #
        # Check for unchanged message specifically
        return [] if output =~ /unchanged: 1/i || output =~ /not changed/i

        results = []
        secret  = false

        output.each_line do |line|
          if line =~ /secret key imported/
            secret = true
          elsif (match = line.match(/key\s+([0-9A-F]+):\s+.*"([^"]*)"/i))
            name, email_addr = parse_user_id(match[2])
            results << {key_id: match[1].to_s.strip, private: secret, name: name, email: email_addr}
            secret = false
          end
        end

        # Return results if we found any
        return results unless results.empty?

        # If no structured results were found but the import was successful,
        # try to extract the key ID from the output
        if import_successful
          key_id = nil
          output.each_line do |line|
            if (match = line.match(/key\s+([0-9A-F]+):/i))
              key_id = match[1].to_s.strip
            end
          end

          return [{key_id: key_id, private: false, name: nil, email: nil}] if key_id
        end

        # Return empty array if we couldn't parse anything but the import was successful
        return [] if import_successful
      end

      raise(Pgp::Failure, "GPG Failed importing key: #{err}#{out}")
    end

    # Returns [String, String] the name and email address of a user id, such as `"Joe Bloggs <j@bloggs.net>"`.
    # The email address is nil when the user id does not have one.
    def self.parse_user_id(user_id)
      match = user_id.match(/\A(.*?)\s*<([^>]*)>\z/)
      match ? [match[1].strip, match[2].strip] : [user_id.strip, nil]
    end

    private_class_method :parse_user_id

    # Imports the supplied key and then marks it as trusted at the supplied trust level.
    #
    # Returns [String] email for the supplied key, or its key id when no email is present.
    #
    # key: [String]
    #   The public (or private) key to import and trust.
    #
    # trust_level: [Integer]
    #   The owner-trust level to assign to the imported key, the same levels used by `set_trust`:
    #     1 : Undefined  (no opinion)
    #     2 : Never      (do not trust)
    #     3 : Marginal
    #     4 : Full
    #     5 : Ultimate
    #   Default: 5 : Ultimate
    #
    # SECURITY WARNING:
    #   Only import and trust keys received from a verified, trusted source.
    #   The default trust level is `5` (Ultimate), which tells GPG to treat the imported key
    #   as if it were one of your own keys. An ultimately trusted key is implicitly valid and
    #   can in turn confer validity on other keys it has signed. Importing an attacker supplied
    #   key at this level allows that attacker to impersonate other recipients.
    #   When the key cannot be fully verified, supply a lower `trust_level`.
    #
    # Notes:
    # - If the same email address has multiple keys then only the first is currently trusted.
    def self.import_and_trust(key:, trust_level: 5)
      info = import_and_trust_key_info(key: key, trust_level: trust_level)
      info[:email] || info[:key_id]
    end

    # Imports and trusts the supplied key, see #import_and_trust.
    #
    # Returns [String] the recipient to encrypt to: the key's fingerprint when gpg supplies it,
    # otherwise the email address or key id returned by #import_and_trust.
    #
    # Encrypting to the fingerprint ensures that the imported key is used, since gpg looks up an
    # email address in the keyring, where another key may have the same email address.
    #
    # When `trust_level` is nil, the key is imported without changing its trust.
    #
    # Used internally by the PGP reader and writer.
    def self.import_and_trust_recipient(key:, trust_level: 5)
      info   = import_and_trust_key_info(key: key, trust_level: trust_level)
      key_id = info[:key_id].to_s
      # gpg v2.1 and later supply the full fingerprint. Earlier versions only supply a short key id, which is not unique.
      return key_id if fingerprint?(key_id)

      info[:email] || info[:key_id]
    end

    # Returns [Hash] the key info for the supplied key, after importing and trusting it.
    def self.import_and_trust_key_info(key:, trust_level:)
      raise(ArgumentError, "Key cannot be empty") if key.nil? || (key == "")

      infos = key_info(key: key)
      info  = infos.last&.dup || {}
      # When a key has several user ids, only the entry for its first user id includes the key id.
      info[:key_id] ||= infos.reverse_each.find { |entry| entry[:key_id] }&.fetch(:key_id)

      email  = info[:email]
      key_id = info[:key_id]
      raise(ArgumentError, "Recipient email or key id cannot be extracted from supplied key") unless email || key_id

      import(key: key)
      # Without a trust level, the trust of the key is not changed.
      set_trust(email: email, key_id: key_id, level: trust_level) if trust_level
      info
    end
    private_class_method :import_and_trust_key_info

    # Set the trust level for an existing key.
    #
    # Returns [String] output if the trust was successfully updated
    # Returns nil if the email was not found
    #
    # After importing keys, they are not trusted and the relevant trust level must be set.
    #
    # key_id: [String]
    #   The fingerprint of the key, as hexadecimal digits only.
    #   Raises ArgumentError when it contains any other characters.
    #
    # level: [Integer]
    #   The owner-trust level to assign to the key:
    #     1 : Undefined  (no opinion)
    #     2 : Never      (do not trust)
    #     3 : Marginal
    #     4 : Full
    #     5 : Ultimate
    #   Default: 5 : Ultimate
    #
    # SECURITY WARNING:
    #   Only trust keys received from a verified, trusted source.
    #   The default trust level is `5` (Ultimate), which tells GPG to treat the key
    #   as if it were one of your own keys. An ultimately trusted key is implicitly valid and
    #   can in turn confer validity on other keys it has signed. Trusting an attacker supplied
    #   key at this level allows that attacker to impersonate other recipients.
    #   When the key cannot be fully verified, supply a lower `level`.
    def self.set_trust(email: nil, key_id: nil, level: 5)
      # The key_id is written into gpg's ownertrust input, where any other character, such as a newline,
      # could add trust lines for other keys.
      if key_id && !key_id.to_s.match?(/\A\h+\z/)
        raise(ArgumentError, "Invalid :key_id, it must only contain hexadecimal digits: #{key_id.inspect}")
      end

      version_check
      fingerprint = key_id || fingerprint(email: email)
      return unless fingerprint

      command          = gpg_command("--import-ownertrust")
      trust            = "#{fingerprint}:#{level + 1}:\n"
      out, err, status = Open3.capture3(*command, stdin_data: trust)
      IOStreams.logger&.debug { "IOStreams::Pgp.set_trust: #{command.shelljoin}\n#{err}#{out}" }

      raise(Pgp::Failure, "GPG Failed trusting key: #{err} #{out}") unless status.success?

      err
    end

    # Internal: resolve an email address to a key fingerprint.
    # Public callers should identify keys by `key_id` (see #list_keys / #key_info).
    def self.fingerprint(email:)
      version_check
      command = gpg_command("--list-keys", "--fingerprint", "--with-colons", "--", user_id(email))
      Open3.popen2e(*command) do |_stdin, out, waith_thr|
        output = out.read.chomp
        if !waith_thr.value.success? && output !~ /(public key not found|No public key)/i
          raise(Pgp::Failure, "GPG Failed calling #{executable} to list keys for #{email}: #{output}")
        end

        output.each_line do |line|
          if (match = line.match(/\Afpr.*::([^:]*):\Z/))
            return match[1]
          end
        end
        nil
      end
    end
    private_class_method :fingerprint

    # Returns [Array<String>] the fingerprints of the primary keys that gpg finds for the supplied
    # email address, key id or fingerprint, see `user_id`, or [] when there are none.
    #
    # Used internally by the PGP reader to check who signed a file.
    def self.primary_fingerprints(value)
      version_check
      command = gpg_command("--list-keys", "--with-colons", "--", user_id(value))
      out, err, status = Open3.capture3(*command, binmode: true)
      unless status.success?
        return [] if err =~ /(not found|No public key|key not available)/i

        raise(Pgp::Failure, "GPG Failed calling '#{executable}' to list keys for #{value}: #{err}#{out}")
      end

      # A primary key is listed as `pub`, followed by its `fpr`, then its subkeys as `sub`, each followed by its own.
      fingerprints = []
      primary      = false
      out.each_line do |line|
        fields = line.split(":")
        case fields[0]
        when "pub"
          primary = true
        when "fpr"
          fingerprints << fields[9] if primary
          primary = false
        end
      end
      fingerprints
    end

    # Returns [String] the version of pgp currently installed
    def self.pgp_version
      @pgp_version ||= begin
        command          = gpg_command("--version")
        out, err, status = Open3.capture3(*command)
        IOStreams.logger&.debug { "IOStreams::Pgp.version: #{command.shelljoin}\n#{err}#{out}" }
        raise(Pgp::Failure, "GPG Failed calling #{executable} --version: #{err}#{out}") unless status.success?

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
      end
    end

    # Returns [true|false] whether the installed gpg is at least the supplied version, such as "2.1".
    # Versions are compared by their numbers, so that for example 2.10 is later than 2.4.
    def self.version_at_least?(version)
      Gem::Version.new(pgp_version.to_s) >= Gem::Version.new(version)
    end

    # Returns [Array<String>] the arguments that stop gpg from asking pinentry for a passphrase, which fails without
    # a tty, so that it reads the one supplied with `--passphrase-fd`, and from caching the session keys of the
    # data that it decrypts.
    #
    # Used internally, including by the PGP reader and writer.
    def self.passphrase_args
      args = []
      # Loopback pinentry is available from GnuPG 2.1.
      args += ["--pinentry-mode", "loopback"] if version_at_least?("2.1")
      # Avoid caching session keys, from GnuPG 2.4.
      args << "--no-symkey-cache" if version_at_least?("2.4")
      args
    end

    # Returns [true|false] whether gpg can encrypt to a key in a file supplied with `--recipient-file`, which is
    # available from GnuPG 2.1.14.
    #
    # Used internally by the PGP writer.
    def self.recipient_file?
      version_at_least?("2.1.14")
    end

    # Returns [true|false] whether the value is the full fingerprint of a key: 40 hexadecimal digits for a v4 key,
    # or 64 for a v5 or v6 key. Not a short key id, which is not unique, nor an email address.
    #
    # Used internally, including by the PGP reader and writer.
    def self.fingerprint?(value)
      value.to_s.match?(/\A(\h{40}|\h{64})\z/)
    end

    def self.version_check
      # Previously, this method raised an error for versions >= 2.4
      # Now we support versions up to and including 2.4.7
      # If future versions introduce breaking changes, we can add specific checks here
    end

    # v2.4.7 output:
    #   pub   rsa3072 2023-05-15 [SC] [expires: 2025-05-14]
    #         CB3E582C87C4D569C52F4A28C0A5F177F20E39B0
    #   uid           [ultimate] Joe Bloggs <pgp_test@iostreams.net>
    #   sub   rsa3072 2023-05-15 [E] [expires: 2025-05-14]
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
        if (match = line.match(/(pub|sec)\s+(\D+)(\d+)\s+(\d+-\d+-\d+)(\s+\[.*\])?(.*)/))
          # v2.2/v2.4:    pub   rsa1024 2017-10-24 [SCEA]
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
        elsif (match = line.match(/\s+([A-Z0-9]{16,64})/))
          # v2.2/v2.4 key id on separate line:
          # 18A0FC1C09C0D8AE34CE659257DC4AE323C7368C
          # Or shorter format: 7932AB23D7238F6B
          # Or a 64 digit fingerprint for v5 and v6 keys.
          hash[:key_id] ||= match[1]
        end
      end
      results
    end

    def self.reject_newlines!(**fields)
      fields.each_pair do |field, value|
        next if value.nil?
        raise(ArgumentError, "IOStreams::Pgp.generate_key: :#{field} cannot contain newlines") if value.to_s =~ /[\r\n]/
      end
    end

    def self.delete_public_or_private_keys(email: nil, key_id: nil, private: false)
      keys = private ? "secret-keys" : "keys"

      list = email ? list_keys(email: email, private: private) : list_keys(key_id: key_id)
      return false if list.empty?

      list.each do |key_info|
        key_id = key_info[:key_id]
        next unless key_id

        command          = gpg_command("--batch", "--no-tty", "--yes", "--delete-#{keys}", "--", key_id)
        out, err, status = Open3.capture3(*command, binmode: true)
        IOStreams.logger&.debug { "IOStreams::Pgp.delete_keys: #{command.shelljoin}\n#{err}#{out}" }

        unless status.success?
          raise(Pgp::Failure, "GPG Failed calling #{executable} to delete #{keys} for #{email || key_id}: #{err}: #{out}")
        end
        raise(Pgp::Failure, "GPG Failed to delete #{keys} for #{email || key_id} #{err.strip}:#{out}") if out.include?("error")
      end
      true
    end

    def self.delete_public_or_private_keys_v1(email: nil, key_id: nil, private: false)
      keys = private ? "secret-keys" : "keys"

      # List the fingerprints, then delete each one. Previously this shelled out
      # to a `for` loop, which allowed shell injection via :email / :key_id.
      list_command        = gpg_command("--list-#{keys}", "--with-colons", "--fingerprint", "--", user_id(email || key_id))
      list_out, list_err, = Open3.capture3(*list_command, binmode: true)
      IOStreams.logger&.debug { "IOStreams::Pgp.delete_keys: #{list_command.shelljoin}\n#{list_err}: #{list_out}" }

      return false if list_err =~ /(not found|no public key)/i

      fingerprints = list_out.each_line.select { |line| line.start_with?("fpr") }.map { |line| line.split(":")[9] }.compact
      return false if fingerprints.empty?

      fingerprints.each do |fingerprint|
        command          = gpg_command("--batch", "--no-tty", "--yes", "--delete-#{keys}", "--", fingerprint)
        out, err, status = Open3.capture3(*command, binmode: true)
        IOStreams.logger&.debug { "IOStreams::Pgp.delete_keys: #{command.shelljoin}\n#{err}: #{out}" }

        unless status.success?
          raise(Pgp::Failure, "GPG Failed calling #{executable} to delete #{keys} for #{email || key_id}: #{err}: #{out}")
        end
        raise(Pgp::Failure, "GPG Failed to delete #{keys} for #{email || key_id} #{err.strip}: #{out}") if out.include?("error")
      end

      true
    end
  end
end
