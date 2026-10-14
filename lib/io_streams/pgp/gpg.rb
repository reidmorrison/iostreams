# frozen_string_literal: true

require "open3"

module IOStreams
  module Pgp
    # What IOStreams knows about the installed gpg, see `IOStreams::Pgp.executable`: how to run it, the features that its
    # version supports, see `IOStreams::Pgp.pgp_version`, and how it finds a key.
    #
    # Used internally by `IOStreams::Pgp`, and by its reader and writer, so that these are not public methods of
    # `IOStreams::Pgp`.
    module Gpg
      # Runs gpg with the supplied command, see `IOStreams::Pgp.gpg_command`, like `Open3.capture3`, with its options.
      #
      # Returns [Array(String, String, Process::Status)] what gpg wrote to its stdout and stderr, and how it exited.
      # Raises Pgp::Failure when gpg cannot be run, such as when GnuPG is not installed.
      def self.capture3(command, **)
        Open3.capture3(*command, **)
      rescue SystemCallError => e
        raise(cannot_run(e))
      end

      # Starts gpg with the supplied command, see `IOStreams::Pgp.gpg_command`, like `Process.spawn`, with its options.
      #
      # Returns [Integer] the process id of gpg.
      # Raises Pgp::Failure when gpg cannot be run, such as when GnuPG is not installed.
      def self.spawn(command, options)
        ::Process.spawn(*command, options)
      rescue SystemCallError => e
        raise(cannot_run(e))
      end

      # Returns [Pgp::Failure] the failure to run gpg, naming the executable, since the system call's error names only
      # the program that it could not run, such as `sudo` for "sudo -u pgp gpg".
      def self.cannot_run(error)
        Pgp::Failure.new("GPG Failed to run the gpg executable #{Pgp.executable.inspect}: #{error.message}. " \
                         "Install GnuPG, or set IOStreams::Pgp.executable to the gpg executable")
      end
      private_class_method :cannot_run

      # Returns [String] the supplied email address or key id, in the form that gpg uses to find the key.
      #
      # gpg treats a bare email address as a case-insensitive search for any user id containing it, so that
      # `bob@example.com` also finds `jimbob@example.com` and `bob@example.com.attacker.net`. Enclosing an
      # email address in `<` and `>` only finds keys with exactly that email address, ignoring case.
      # Anything else, such as a key id, fingerprint, name, an email address already in `<` and `>`, or a value
      # that starts with one of gpg's search prefixes, such as `*` for a substring search, is returned unchanged.
      def self.user_id(value)
        value = value.to_s
        value.match?(/\A[^<>@\s*=&+#^][^<>@\s]*@[^<>@\s]+\z/) ? "<#{value}>" : value
      end

      # Returns [true|false] whether the value is the full fingerprint of a key: 40 hexadecimal digits for a v4 key,
      # or 64 for a v5 or v6 key. Not a short key id, which is not unique, nor an email address.
      def self.fingerprint?(value)
        value.to_s.match?(/\A(\h{40}|\h{64})\z/)
      end

      # Returns [Array<String>] the fingerprints of the primary keys that gpg finds for the supplied
      # email address, key id or fingerprint, see `.user_id`, or [] when there are none.
      #
      # Used by the PGP reader to check who signed a file.
      def self.primary_fingerprints(value)
        command = Pgp.gpg_command("--list-keys", "--with-colons", "--", user_id(value))
        out, err, status = capture3(command, binmode: true)
        unless status.success?
          return [] if err =~ /(not found|No public key|key not available)/i

          raise(Pgp::Failure, "GPG Failed calling '#{Pgp.executable}' to list keys for #{value}: #{err}#{out}")
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

      # Returns [true|false] whether the installed gpg is at least the supplied version, such as "2.1".
      # Versions are compared by their numbers, so that for example 2.10 is later than 2.4.
      def self.version_at_least?(version)
        Gem::Version.new(Pgp.pgp_version.to_s) >= Gem::Version.new(version)
      end

      # Returns [Array<String>] the arguments that stop gpg from asking pinentry for a passphrase, which fails without
      # a tty, so that it reads the one supplied with `--passphrase-fd`, and from caching the session keys of the
      # data that it decrypts.
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
      def self.recipient_file?
        version_at_least?("2.1.14")
      end
    end
  end
end
