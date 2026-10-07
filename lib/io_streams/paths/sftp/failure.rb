module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      # Returns the kind of failure, such as `IOStreams::Errors::NotFound`, for a failure of the sftp program, which
      # reads and writes files, or of net-sftp, which lists and deletes them, see `IOStreams::Errors::StorageError`.
      module Failure
        # The kind of failure that each SFTP status code means, see `Listing`.
        STATUS_KINDS = {
          Listing::NO_SUCH_FILE => Errors::NotFound,
          Listing::NO_SUCH_PATH => Errors::NotFound
        }.freeze

        # The kind of failure that a line in the output of the sftp program means.
        #
        # OpenSSH prints the status of a request for a remote file after its name, such as
        # `remote open "/data/a.csv": No such file or directory` when reading, `dest open "/data/a.csv": ...` when
        # writing, and `remote open("/data/a.csv"): ...` or `Couldn't stat remote file: ...` before OpenSSH 8.7.
        # It prints `File "/data/a.csv" not found.` for a file to read that does not exist.
        OUTPUT_KINDS = {
          Errors::NotFound => Regexp.union(
            /\AFile ".*" not found\.\z/,
            /\A(?:remote open|dest open|Couldn't stat remote file).*: No such file or directory\z/
          )
        }.freeze

        # Returns [Module] the kind of failure that an exception raised by net-sftp means, or nil when it is none of them.
        def self.kind(exception)
          STATUS_KINDS[exception.code] if exception.is_a?(Net::SFTP::StatusException)
        end

        # Returns [Module] the kind of failure that the output of the sftp program means, or nil when it is none of them.
        def self.output_kind(out)
          lines = out.to_s.lines(chomp: true)
          OUTPUT_KINDS.each { |kind, pattern| return kind if lines.any? { |line| line.match?(pattern) } }
          nil
        end
      end
    end
  end
end
