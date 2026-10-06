module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      # Lists the files on the remote sftp server for `SFTP#each_child`, like Dir.glob.
      #
      # Only the directories that the pattern can match within are listed, so for example `*.csv` only lists
      # the directory, and `**/*.csv` lists every directory within it.
      module Listing
        # SFTP status codes.
        NO_SUCH_FILE      = 2
        PERMISSION_DENIED = 3

        # Yields [String, Hash] the name relative to the directory, and the attributes, of each file
        # within the remote directory whose name the matcher matches, and of each directory when `directories`.
        # Only the sub-directories that the matcher can match names within are listed,
        # see `IOStreams::Paths::Matcher#depth`.
        #
        # Yields nothing when the directory does not exist, or is not a directory.
        def self.each(sftp, directory, matcher, directories:)
          attributes = remote_attributes(sftp, directory)
          return unless attributes&.directory?

          each_entry(sftp, directory, nil, matcher.depth) do |name, entry|
            next if !directories && !entry.file?
            next unless matcher.match?(name)

            yield(name, entry.attributes.attributes)
          end
        end

        # Yields the name, relative to the directory, and the entry, of each entry in the remote directory,
        # and the entries in its sub-directories upto `depth` levels down, or every level when nil.
        # A sub-directory that no longer exists, or cannot be read, is skipped, like Dir.glob.
        def self.each_entry(sftp, directory, prefix, depth, &block)
          entries = entries(sftp, directory, prefix)
          return unless entries

          entries.sort_by(&:name).each do |entry|
            next if %w[. ..].include?(entry.name)

            name = prefix ? ::File.join(prefix, entry.name) : entry.name
            yield(name, entry)
            next unless entry.directory? && (depth.nil? || depth.positive?)

            each_entry(sftp, directory, name, depth && (depth - 1), &block)
          end
        end

        # Returns [Array] the entries in the remote directory, or in the sub-directory `prefix` within it,
        # or nil when the sub-directory no longer exists, or cannot be read.
        def self.entries(sftp, directory, prefix)
          sftp.dir.entries(prefix ? ::File.join(directory, prefix) : directory)
        rescue Net::SFTP::StatusException => e
          raise if prefix.nil? || ![NO_SUCH_FILE, PERMISSION_DENIED].include?(e.code)

          nil
        end

        # Returns the attributes of the remote file or directory, or nil when it does not exist.
        # Also used by `SFTP#exist?`, `#size`, `#file?`, `#directory?`, `#empty?`, and `#each_child` for an exact name.
        def self.remote_attributes(sftp, remote_name)
          sftp.stat!(remote_name)
        rescue Net::SFTP::StatusException => e
          raise unless e.code == NO_SUCH_FILE

          nil
        end

        private_class_method :each_entry, :entries
      end
    end
  end
end
