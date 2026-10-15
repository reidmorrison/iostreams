# frozen_string_literal: true

module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      # The conventions of the sftp program, which reads and writes files, see `SFTP#run_sftp`: how it names its
      # destination, its log levels, and that it reads a key from a file. Its batch commands are built by `Batch`.
      module Program
        # The ssh options that hold a key, and the ssh option of the sftp program that names a file holding it instead.
        KEY_FILE_OPTIONS = {"IdentityKey" => "IdentityFile", "HostKey" => "UserKnownHostsFile"}.freeze

        # Returns [String] the destination of the sftp program: the host, after the user name when one is supplied.
        # Without a user name, sftp uses the one from the ssh config, or the current user. A host that is an IPv6
        # address, such as `::1`, is within `[` and `]`, since sftp reads a `:` in the destination as the start of a path.
        def self.destination(hostname, username)
          host = hostname.include?(":") ? "[#{hostname}]" : hostname
          username ? "#{username}@#{host}" : host
        end

        # Returns [String] the sftp LogLevel for the level of a logger, such as `IOStreams.logger`, which is a Symbol
        # for a logger such as SemanticLogger.
        def self.log_level(level)
          case level
          when :trace
            "DEBUG3"
          when :warn
            "ERROR"
          when Symbol
            level.to_s
          else
            "INFO"
          end
        end

        # Yields [Hash] the ssh options, with the key held by an `IdentityKey` or `HostKey` option written to a temp
        # file, which the `IdentityFile` or `UserKnownHostsFile` option names instead, see KEY_FILE_OPTIONS. The file can
        # only be read by the current user, as sftp requires of a private key, and is deleted once the block returns.
        def self.with_key_files(ssh_options, &block)
          option = KEY_FILE_OPTIONS.keys.find { |name| ssh_options.key?(name) }
          return yield(ssh_options) unless option

          options   = ssh_options.dup
          key       = options.delete(option)
          file_name = KEY_FILE_OPTIONS[option]
          Utils.private_temp_file("iostreams-sftp-args", "key", purpose: "the ssh #{file_name}") do |temp_file_name|
            ::File.binwrite(temp_file_name, key)
            options[file_name] = temp_file_name
            with_key_files(options, &block)
          end
        end
      end
    end
  end
end
