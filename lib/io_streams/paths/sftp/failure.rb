module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      # Returns the kind of failure, such as `IOStreams::Errors::NotFound`, for a failure of the sftp program, which
      # reads and writes files, or of net-sftp, which lists and deletes them, see `IOStreams::Errors::StorageError`.
      module Failure
        # SFTP status codes for a connection that failed.
        NO_CONNECTION   = 6
        CONNECTION_LOST = 7

        # The kind of failure that each SFTP status code means, see `Listing`.
        STATUS_KINDS = {
          Listing::NO_SUCH_FILE      => Errors::NotFound,
          Listing::NO_SUCH_PATH      => Errors::NotFound,
          Listing::PERMISSION_DENIED => Errors::PermissionDenied,
          NO_CONNECTION              => Errors::Unavailable,
          CONNECTION_LOST            => Errors::Unavailable
        }.freeze

        # The kind of failure that a line in the output of the sftp program means.
        #
        # OpenSSH prints the status of a request for a remote file after its name, such as
        # `remote open "/data/a.csv": No such file or directory` when reading, `dest open "/data/a.csv": ...` when
        # writing, and `remote open("/data/a.csv"): ...` or `Couldn't stat remote file: ...` before OpenSSH 8.7.
        # It prints `File "/data/a.csv" not found.` for a file to read that does not exist,
        # `jack@example.org: Permission denied (publickey,password).` when it cannot log in, and for example
        # `ssh: connect to host example.org port 22: Connection refused` when it cannot reach the server.
        OUTPUT_KINDS = {
          Errors::NotFound         => Regexp.union(
            /\AFile ".*" not found\.\z/,
            /\A(?:remote open|dest open|Couldn't stat remote file).*: No such file or directory\z/
          ),
          Errors::PermissionDenied => Regexp.union(
            /\A(?:remote open|dest open|Couldn't stat remote file).*: Permission denied\z/,
            /Permission denied \(.*\)\.\z/
          ),
          Errors::Unavailable      => Regexp.union(
            /\Assh: connect to host .* port \d+: /,
            /\Assh: Could not resolve hostname /,
            /\A(?:kex|ssh)_exchange_identification: /,
            /\AConnection (?:closed|reset) by /,
            /\AConnection timed out during banner exchange/,
            /\ATimeout, server .* not responding\./,
            /\Aclient_loop: send disconnect: /
          )
        }.freeze

        # The exceptions that net-ssh raises when it cannot connect to the server, see `SFTP#with_net_sftp`.
        CONNECTION_ERRORS = [
          SocketError, Errno::ECONNABORTED, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
          Errno::ENETUNREACH, Errno::ETIMEDOUT
        ].freeze

        # The exit status of sshpass when the password is not correct.
        SSHPASS_INCORRECT_PASSWORD = 5

        # Returns [Module] the kind of failure that an exception raised by net-sftp, or net-ssh, means, or nil when it is
        # none of them.
        #
        # net-ssh is loaded with net-sftp, unless Net::SFTP has been replaced, for example in a test.
        def self.kind(exception)
          if exception.is_a?(Net::SFTP::StatusException)
            STATUS_KINDS[exception.code]
          elsif defined?(Net::SSH::Exception) && exception.is_a?(Net::SSH::Exception)
            net_ssh_kind(exception)
          end
        end

        # Returns [Module] the kind of failure that an exception raised by net-ssh means.
        def self.net_ssh_kind(exception)
          case exception
          when Net::SSH::AuthenticationFailed
            Errors::PermissionDenied
          when Net::SSH::ConnectionTimeout, Net::SSH::Disconnect
            Errors::Unavailable
          end
        end
        private_class_method :net_ssh_kind

        # Returns [Module] the kind of failure that the output and exit status of the sftp program mean, or nil when
        # they are none of them. With `sshpass`, the program was run by sshpass to supply the password.
        def self.output_kind(out, status, sshpass:)
          lines = out.to_s.lines(chomp: true)
          OUTPUT_KINDS.each { |kind, pattern| return kind if lines.any? { |line| line.match?(pattern) } }
          Errors::PermissionDenied if sshpass && status&.exitstatus == SSHPASS_INCORRECT_PASSWORD
        end
      end
    end
  end
end
