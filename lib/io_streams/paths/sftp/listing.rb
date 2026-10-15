# frozen_string_literal: true

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
        # Sent instead of NO_SUCH_FILE by some servers, from version 4 of the SFTP protocol.
        NO_SUCH_PATH      = 10

        # The SFTP status codes that mean the file or directory does not exist.
        NOT_FOUND = [NO_SUCH_FILE, NO_SUCH_PATH].freeze

        # Yields [String, Hash] the name relative to the directory, and the attributes, of each file
        # within the remote directory whose name the matcher matches, and of each directory when `directories`.
        # Only the sub-directories that the matcher can match names within are listed,
        # see `IOStreams::Paths::Matcher#depth`.
        #
        # A symbolic link is a file or a directory by what it refers to, with its attributes, as for an exact name, see
        # `.remote_attributes`, and a local path. A directory that a link refers to is not listed, like `Dir.glob`.
        #
        # Yields nothing when the directory does not exist, or is not a directory.
        def self.each(sftp, directory, matcher, directories:)
          attributes = remote_attributes(sftp, directory)
          return unless attributes&.directory?

          each_entry(sftp, directory, nil, matcher.depth) do |name, entry|
            next unless matcher.match?(name)

            # A server lists a link with its own attributes.
            attributes = (entry.symlink? && link_attributes(sftp, ::File.join(directory, name))) || entry.attributes
            next if !directories && !attributes.file?

            yield(name, attributes.attributes)
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

            name = prefix ? ::File.join(prefix, utf8(entry.name)) : utf8(entry.name)
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
          raise if prefix.nil? || !(NOT_FOUND.include?(e.code) || e.code == PERMISSION_DENIED)

          nil
        end

        # Deletes the remote directory and everything within it, deepest first, without following symbolic links.
        # Used by `SFTP#delete_all`.
        def self.remove_tree(sftp, directory)
          sftp.dir.entries(directory).each do |entry|
            next if %w[. ..].include?(entry.name)

            name = ::File.join(directory, utf8(entry.name))
            entry.directory? ? remove_tree(sftp, name) : sftp.remove!(name)
          end
          sftp.rmdir!(directory)
        end

        # Returns [String] the name of a remote file as UTF-8. Net::SFTP returns each name as bytes, which servers send
        # in UTF-8, as version 4 of the SFTP protocol requires, and as OpenSSH does on a file system of UTF-8 names.
        # A name in another encoding, such as Latin-1, is then not valid UTF-8, see `IOStreams::Utils.matchable`.
        def self.utf8(name)
          name.dup.force_encoding(Encoding::UTF_8)
        end

        # Returns the attributes of the remote file or directory, or nil when it does not exist.
        # Also used by `SFTP#exist?`, `#size`, `#file?`, `#directory?`, `#empty?`, and `#each_child` for an exact name.
        def self.remote_attributes(sftp, remote_name)
          sftp.stat!(remote_name)
        rescue Net::SFTP::StatusException => e
          raise unless NOT_FOUND.include?(e.code)

          nil
        end

        # Returns the attributes of what the symbolic link refers to, or nil when it does not exist, or cannot be read.
        def self.link_attributes(sftp, link)
          sftp.stat!(link)
        rescue Net::SFTP::StatusException => e
          raise unless NOT_FOUND.include?(e.code) || e.code == PERMISSION_DENIED

          nil
        end

        private_class_method :each_entry, :entries, :utf8, :link_attributes
      end
    end
  end
end
