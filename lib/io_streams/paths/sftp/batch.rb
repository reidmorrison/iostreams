module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      # The commands that the sftp program reads from its batch file to transfer a file, see `SFTP#sftp_download`
      # and `SFTP#sftp_upload`.
      #
      # Each file name is in double quotes, with each `"` and `\` escaped with a backslash and every other byte as it
      # is, so that a name that is not ASCII, or not valid UTF-8, names the same file. `String#inspect` would escape
      # those bytes, so that sftp looked for another file.
      module Batch
        # A control character, which a command, being a line, cannot hold.
        CONTROL_CHARACTER = /[\x00-\x1F\x7F]/n

        # Returns [String] the command to download the remote file into the local file.
        def self.get(remote_file_name, local_file_name)
          "get #{quote(remote_file_name)} #{quote(local_file_name)}"
        end

        # Returns [Array<String>] the commands to upload the local file into the remote file, after creating each
        # directory of the remote file, from the top down, when `mkpath` is true. The `-` prefix of `mkdir` ignores
        # the failure when a directory already exists.
        def self.put(local_file_name, remote_file_name, mkpath: false)
          commands = mkpath ? parent_directories(remote_file_name).map { |directory| "-mkdir #{quote(directory)}" } : []
          commands << "put #{quote(local_file_name)} #{quote(remote_file_name)}"
        end

        # Returns [Array<String>] each directory of the file name, from the top down.
        # For example `["/a", "/a/b"]` for `"/a/b/file.csv"`.
        def self.parent_directories(file_name)
          directories = []
          directory   = ::File.dirname(file_name)
          until ["/", "."].include?(directory)
            directories.unshift(directory)
            directory = ::File.dirname(directory)
          end
          directories
        end

        # Returns [String] the file name in double quotes.
        #
        # Raises ArgumentError for a name with a control character, such as a line feed.
        def self.quote(file_name)
          bytes = file_name.b
          if bytes.match?(CONTROL_CHARACTER)
            raise(ArgumentError, "The sftp program cannot transfer a file whose name has a control character: " \
                                 "#{Utils.display_text(file_name).inspect}")
          end

          %("#{bytes.gsub(/["\\]/n) { |char| "\\#{char}" }}")
        end
      end
    end
  end
end
