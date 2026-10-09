module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      # Translates the ssh options supplied for the sftp executable into options for net-ssh,
      # which `SFTP#each_child` uses to list files instead of the sftp executable.
      #
      # The net-ssh options match those that SFTP passes to the sftp executable.
      module NetSSH
        # The ssh options that net-ssh supports.
        OPTIONS = %w[
          HostKey IdentityKey IdentityFile UserKnownHostsFile StrictHostKeyChecking
          ConnectTimeout ServerAliveInterval ServerAliveCountMax LogLevel
        ].freeze

        # Yields [Hash] the net-ssh options.
        #
        # Raises [ArgumentError] when `ssh_options` includes an option that is not in `OPTIONS`.
        def self.options(ssh_options, port:, password:)
          options = {port: port, max_pkt_size: 65_536, non_interactive: true}
          options[:logger] = IOStreams.logger if IOStreams.logger
          # Like the sftp executable, only use the password when one is supplied, and otherwise only public keys.
          if password
            options[:password]     = password
            options[:auth_methods] = %w[password keyboard-interactive]
          else
            options[:auth_methods] = %w[publickey]
          end
          # Like the sftp executable, which uses `StrictHostKeyChecking=yes`, instead of the
          # net-ssh default of trusting a host key the first time it is seen.
          options[:verify_host_key] = :always

          ssh_options.each_pair { |key, value| add(options, key, value) }
          return yield(options) unless ssh_options.key?("HostKey")

          # Like the sftp executable, the host key replaces the user's known_hosts file.
          Utils.private_temp_file("iostreams-sftp-known-hosts", purpose: "the ssh UserKnownHostsFile") do |file_name|
            ::File.binwrite(file_name, ssh_options["HostKey"])
            options[:user_known_hosts_file] = [file_name]
            yield(options)
          end
        end

        def self.add(options, key, value)
          case key
          when "HostKey"
            # Written to a temp file by `.options`.
          when "IdentityKey"
            (options[:key_data] ||= []) << value
            options[:keys_only] = true
          when "IdentityFile"
            (options[:keys] ||= []) << value
            options[:keys_only] = true
          when "UserKnownHostsFile"
            options[:user_known_hosts_file] = value.to_s.split
          when "StrictHostKeyChecking"
            options[:verify_host_key] = verify_host_key(value)
          when "ConnectTimeout"
            options[:timeout] = Integer(value)
          when "ServerAliveInterval"
            options[:keepalive]          = Integer(value).positive?
            options[:keepalive_interval] = Integer(value)
          when "ServerAliveCountMax"
            options[:keepalive_maxcount] = Integer(value)
          when "LogLevel"
            options[:verbose] = log_level(value)
          else
            raise(ArgumentError,
                  "SFTP #each_child does not support the ssh option #{key.inspect}. It supports: #{OPTIONS.join(', ')}")
          end
        end

        def self.verify_host_key(value)
          case value.to_s.downcase
          when "yes", "ask"
            :always
          when "accept-new"
            :accept_new
          when "no", "off"
            :never
          else
            raise(ArgumentError, "Invalid StrictHostKeyChecking value: #{value.inspect}")
          end
        end

        def self.log_level(value)
          case value.to_s.upcase
          when "QUIET", "FATAL"
            :fatal
          when "ERROR"
            :error
          when "INFO", "VERBOSE"
            :info
          when "DEBUG", "DEBUG1", "DEBUG2", "DEBUG3"
            :debug
          else
            raise(ArgumentError, "Invalid LogLevel value: #{value.inspect}")
          end
        end

        private_class_method :add, :verify_host_key, :log_level
      end
    end
  end
end
