require "open3"

module IOStreams
  module Paths
    # Read a file from a remote sftp server.
    #
    # Example:
    #   IOStreams.
    #     path("sftp://example.org/path/file.txt", username: "jbloggs", password: "secret").
    #     reader do |input|
    #       puts input.read
    #     end
    #
    # Note:
    # - raises Net::SFTP::StatusException when the file could not be read.
    #
    # Write to a file on a remote sftp server.
    #
    # Example:
    #   IOStreams.
    #     path("sftp://example.org/path/file.txt", username: "jbloggs", password: "secret").
    #     writer do |output|
    #       output.write('Hello World')
    #     end
    class SFTP < IOStreams::Path
      class << self
        attr_accessor :sshpass_bin, :sftp_bin, :sshpass_wait_seconds, :before_password_wait_seconds
      end

      @sftp_bin                     = "sftp"
      @sshpass_bin                  = "sshpass"
      @before_password_wait_seconds = 2
      @sshpass_wait_seconds         = 5

      autoload :Listing, "io_streams/paths/sftp/listing"
      autoload :NetSSH, "io_streams/paths/sftp/net_ssh"

      attr_reader :hostname, :username, :ssh_options, :url, :port

      # Stream to a remote file over sftp.
      #
      # url: [String]
      #   "sftp://<host_name>/<file_name>"
      #
      #   The path is absolute, so `sftp://host/data/a.csv` is `/data/a.csv`, and a url without a path,
      #   such as `sftp://host`, is the root directory `/`.
      #   Start the path with `~` for a path within the login directory instead, as curl does:
      #   `sftp://host/~/data/a.csv` is `data/a.csv` within the login directory, and `sftp://host/~`
      #   is the login directory.
      #
      #   SECURITY WARNING:
      #     A username and password supplied in the url remain part of it, so `#to_s` and `#url`
      #     return them, as does any log or error message that includes the path.
      #     Supply them with the `username:` and `password:` arguments instead.
      #
      # username: [String]
      #   Name of user to login with.
      #
      # password: [String]
      #   Password for the user.
      #
      # ssh_options: [Hash]
      #   - IdentityKey [String]
      #     The identity key that this client should use to talk to this host.
      #     Under the covers this value is written to a file and then the file name is passed as `IdentityFile`
      #   - HostKey [String]
      #     The expected SSH Host key that is presented by the remote host.
      #     Instead of storing the host key in the `known_hosts` file, it can be supplied explicity
      #     using this option.
      #     Under the covers this value is written to a file and then the file name is passed as `UserKnownHostsFile`
      #     Notes:
      #     - It must contain the entire line that would be stored in `known_hosts`,
      #       including the hostname, ip address, key type and key value. This value is written as-is into a
      #       "known_hosts" like file and then passed into sftp using the `UserKnownHostsFile` option.
      #     - The easiest way to generate the required is to use `ssh-keyscan` and then supply that value in this field.
      #       For example: `ssh-keyscan hostname`
      #   - Any other options supported by ssh_config.
      #     `man ssh_config` to see all available options.
      #
      #   `#each_child` lists files with the net-sftp gem instead of the sftp executable, so it only supports
      #   these ssh options: HostKey, IdentityKey, IdentityFile, UserKnownHostsFile, StrictHostKeyChecking,
      #   ConnectTimeout, ServerAliveInterval, ServerAliveCountMax and LogLevel. Any other option raises
      #   ArgumentError.
      #   It also needs the ed25519 gem, and the bcrypt_pbkdf gem except on JRuby, when the host key or the
      #   identity key is an ed25519 key. Reading and writing do not, since the sftp executable supports them.
      #
      # Examples:
      #
      #   # Display the contents of a remote file
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", password: "OpenSesame").reader do |io|
      #     puts io.read
      #   end
      #
      #   # Full url showing all the optional elements that can be set via the url:
      #   sftp://username:password@hostname:22/path/file_name
      #
      #   # Display the contents of a remote file, supplying the username and password in the url:
      #   IOStreams.path("sftp://jack:OpenSesame@test.com:22/path/file_name.csv").reader do |io|
      #     puts io.read
      #   end
      #
      #   # Display the contents of a remote file, supplying the username and password as arguments:
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", password: "OpenSesame").reader do |io|
      #     puts io.read
      #   end
      #
      #   # When using the sftp executable use an identity file instead of a password to authenticate:
      #   IOStreams.path("sftp://test.com/path/file_name.csv",
      #                  username:    "jack",
      #                  ssh_options: {IdentityFile: "~/.ssh/private_key"}).reader do |io|
      #     puts io.read
      #   end
      def initialize(url, username: nil, password: nil, ssh_options: {})
        uri = Utils::URI.new(url)
        raise(ArgumentError, "Invalid URL. Required Format: 'sftp://<host_name>/<file_name>'") unless uri.scheme == "sftp"

        @hostname = uri.hostname
        @mkdir    = false
        @username = username || uri.user
        @url      = url
        @password = password || uri.password
        @port     = uri.port || 22
        # Not Ruby 2.5 yet: transform_keys(&:to_s)
        @ssh_options = {}
        ssh_options.each_pair { |key, value| @ssh_options[key.to_s] = value }
        validate_username!

        super(self.class.url_path(uri.path))
      end

      # Returns [String] the path of a url: `~` for the login directory, and `/` for a url without a path.
      def self.url_path(path)
        return "/" if path.empty?

        path.sub(%r{\A/~(?=/|\z)}, "~")
      end

      # Does not support relative file names since there is no concept of current working directory.
      # A path within the login directory, such as `~/a.csv`, is also absolute, like `~/a.csv` for a local file.
      def relative?
        false
      end

      def absolute?
        true
      end

      def to_s
        url
      end

      # Creates the directories of this path, when a file is next written to this path, or to a path
      # joined to it, since each write connects to the server separately.
      # Returns self
      def mkdir
        @mkdir = true
        self
      end

      # Creates the directories of this file, excluding the file name, when the file is next written.
      # Returns self
      def mkpath
        @mkdir = true
        self
      end

      # When path is a file, deletes this file.
      # When path is a directory, attempts to delete this directory. If the directory contains
      # any children it will fail.
      #
      # Returns self
      #
      # Notes:
      # * No error is raised if the file or directory is not present.
      # * Only the file is removed, not any of the parent paths.
      def delete
        authorize!
        Utils.load_soft_dependency("net-sftp", "SFTP delete capability", "net/sftp") unless defined?(Net::SFTP)

        NetSSH.options(ssh_options, port: port, password: password) do |options|
          Net::SFTP.start(hostname, username, options) do |sftp|
            attributes = sftp.lstat!(remote_path)
            attributes.directory? ? sftp.rmdir!(remote_path) : sftp.remove!(remote_path)
          rescue Net::SFTP::StatusException => e
            raise unless e.code == Listing::NO_SUCH_FILE
          end
        end
        self
      end

      # TODO: Add #copy_from shortcut to detect when a file is supplied that does not require conversion.

      # Search for files on the remote sftp server that match the provided pattern, within this path.
      # When the url does not include a path, for example `sftp://sftp.example.org`, it searches
      # the root directory `/`. To search the login directory, use `sftp://sftp.example.org/~`.
      #
      # The pattern matching works like Dir.glob, and is case-insensitive by default, like local and S3 paths.
      # Only the directories that the pattern can match within are listed, so for example `*.csv` only lists
      # this directory, and `**/*.csv` lists every directory within it.
      # A directory within it that cannot be read is skipped, like Dir.glob.
      # When this path does not exist, or is not a directory, nothing is returned.
      #
      # Each child also returns attributes that contain the file size, ownership, file dates and other details.
      #
      # Example Code:
      # IOStreams.
      #   path("sftp://sftp.example.org/my_files", username: username, password: password).
      #   each_child('**/*.{csv,txt}') do |input, attributes|
      #     puts "#{input.to_s} #{attributes}"
      #   end
      #
      # Example Output:
      # sftp://sftp.example.org/my_files/a/b/c/test.txt {:type=>1, :size=>37, :owner=>"test_owner", :group=>"test_group",
      #   :permissions=>420, :atime=>1572378136, :mtime=>1572378136, :link_count=>1, :extended=>{}}
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        authorize!
        Utils.load_soft_dependency("net-sftp", "SFTP glob capability", "net/sftp") unless defined?(Net::SFTP)

        matcher   = Matcher.new(self, pattern, case_sensitive: case_sensitive, hidden: hidden)
        directory = matcher.path
        NetSSH.options(ssh_options, port: port, password: password) do |options|
          Net::SFTP.start(hostname, username, options) do |sftp|
            Listing.each(sftp, directory.remote_path, matcher.pattern, matcher.flags,
                         directories: directories) do |name, attributes|
              child = name ? child_path(name, directory.path) : directory
              yield(child, attributes) if allowed_child?(child)
            end
          end
        end
        nil
      end

      protected

      # Returns [String] the url without the user name, password, or query, which can hold ssh options such as a key.
      def display_name
        url.sub(%r{\A([^:/]+://)[^/?#]*@}, "\\1").sub(/[?#].*\z/m, "")
      end

      # Sets the path, also changing the url to use it, for example when called by `#join` or `#directory`.
      def path=(path)
        # The directory of a path within the login directory, such as `~/a.csv`, is the login directory.
        super([".", ""].include?(path) ? "~" : path)
        separator = self.path.start_with?("/") ? "" : "/"
        @url      = "#{url[%r{\A[^:/]+://[^/?#]*}]}#{separator}#{self.path}"
      end

      # Returns [String] the name of this path on the server, where a path within the login
      # directory, which starts with `~`, is relative.
      def remote_path
        return path unless path.start_with?("~")

        relative = path.delete_prefix("~").delete_prefix("/")
        relative.empty? ? "." : relative
      end

      private

      attr_reader :password

      # Returns [String] the host, port and path, which is compared against the allowed paths.
      # `.` and `..` are resolved the way the sftp server resolves them.
      def allowed_location
        "sftp://#{hostname.to_s.downcase}:#{port}#{normalize_path(path)}".chomp("/")
      end

      # Usernames are passed to the `sftp` executable, so reject values that it could treat as options.
      def validate_username!
        return if username.nil?
        return unless username.to_s.start_with?("-") || username.to_s.match?(/[[:cntrl:]]/)

        raise(ArgumentError, "Invalid SFTP username: it cannot start with '-' or contain control characters")
      end

      # Set the path directly rather than parsing it as part of a URL, since a file name can contain
      # characters such as `?`, `#`, `+` or `%` that a URL parser would treat as a query or as escapes.
      #
      # The supplied name is relative to the supplied directory, which defaults to this path.
      def child_path(name, directory = path)
        server     = port == 22 ? "sftp://#{hostname}" : "sftp://#{hostname}:#{port}"
        child      = self.class.new(server, username: username, password: password, ssh_options: ssh_options)
        child.path = ::File.join(directory, name).freeze
        child
      end

      def stream_reader(&block)
        Utils.private_temp_file("iostreams-sftp-reader") do |file_name|
          sftp_download(remote_path, file_name)
          ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
        end
      end

      def stream_writer(&block)
        Utils.private_temp_file("iostreams-sftp-writer") do |file_name|
          result = ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }
          sftp_upload(file_name, remote_path)
          result
        end
      end

      # Use the sftp executable to download to a local file, via sshpass when a password is supplied
      def sftp_download(remote_file_name, local_file_name)
        with_sftp_args do |args|
          Open3.popen2e(*args) do |writer, reader, waith_thr|
            if password
              # Give time for remote sftp server to get ready to accept the password.
              sleep self.class.before_password_wait_seconds

              writer.puts password

              # Give time for password to be processed and stdin to be passed to sftp process.
              sleep self.class.sshpass_wait_seconds
            end

            writer.puts "get #{remote_file_name.inspect} #{local_file_name.inspect}"
            writer.puts "bye"
            writer.close
            out = reader.read.chomp
            raise_failure("Download", out) unless waith_thr.value.success?

            out
          rescue Errno::EPIPE
            out = begin
              reader.read.chomp
            rescue StandardError
              nil
            end
            raise_failure("Download", out)
          end
        end
      end

      def sftp_upload(local_file_name, remote_file_name)
        with_sftp_args do |args|
          Open3.popen2e(*args) do |writer, reader, waith_thr|
            if password
              writer.puts(password)
              # Give time for password to be processed and stdin to be passed to sftp process.
              sleep self.class.sshpass_wait_seconds
            end
            # The `-` prefix ignores the failure when a directory already exists.
            parent_directories(remote_file_name).each { |directory| writer.puts "-mkdir #{directory.inspect}" } if @mkdir
            writer.puts "put #{local_file_name.inspect} #{remote_file_name.inspect}"
            writer.puts "bye"
            writer.close
            out = reader.read.chomp
            raise_failure("Upload", out) unless waith_thr.value.success?

            out
          rescue Errno::EPIPE
            out = begin
              reader.read.chomp
            rescue StandardError
              nil
            end
            raise_failure("Upload", out)
          end
        end
      end

      # Returns [Array<String>] each directory of the file name, from the top down.
      # For example `["/a", "/a/b"]` for `"/a/b/file.csv"`.
      def parent_directories(file_name)
        directories = []
        directory   = ::File.dirname(file_name)
        until ["/", "."].include?(directory)
          directories.unshift(directory)
          directory = ::File.dirname(directory)
        end
        directories
      end

      # When the server does not prompt for a password, sftp reads the password line as a command
      # and echoes it in its output, so remove it before the output is included in the error.
      def raise_failure(action, out)
        out = out.gsub(password.to_s, "[FILTERED]") if out && !password.to_s.empty?
        raise(
          Errors::CommunicationsFailure,
          "#{action} failed calling #{self.class.sftp_bin}#{" via #{self.class.sshpass_bin}" if password}: #{out}"
        )
      end

      def with_sftp_args
        return yield sftp_args(ssh_options) if !ssh_options.key?("IdentityKey") && !ssh_options.key?("HostKey")

        with_identity_key(ssh_options.dup) do |options|
          with_host_key(options) do |options2|
            yield sftp_args(options2)
          end
        end
      end

      def with_identity_key(options)
        return yield options unless ssh_options.key?("IdentityKey")

        with_temp_file(options, "IdentityFile", options.delete("IdentityKey")) { yield options }
      end

      def with_host_key(options)
        return yield options unless ssh_options.key?("HostKey")

        with_temp_file(options, "UserKnownHostsFile", options.delete("HostKey")) { yield options }
      end

      def with_temp_file(options, option, value)
        # sftp requires that private key is only readable by the current user
        Utils.private_temp_file("iostreams-sftp-args", "key") do |file_name|
          ::File.binwrite(file_name, value)

          options[option] = file_name
          yield options
        end
      end

      def sftp_args(ssh_options)
        # sshpass is only needed to supply the password to sftp.
        args = password ? [self.class.sshpass_bin, self.class.sftp_bin] : [self.class.sftp_bin]
        # Force sftp to use the password when supplied,
        # and stop sftp from prompting for a password when none was supplied.
        if password
          args << "-oBatchMode=no"
          args << "-oNumberOfPasswordPrompts=1"
          args << "-oPubkeyAuthentication=no"
        else
          args << "-oBatchMode=yes"
          args << "-oPasswordAuthentication=no"
        end
        args << "-oIdentitiesOnly=yes" if ssh_options.key?("IdentityFile")
        # Default is ask, but this is non-interactive so make the default fail without asking.
        args << "-oStrictHostKeyChecking=yes" unless ssh_options.key?("StrictHostKeyChecking")
        args << "-oLogLevel=#{map_log_level}" unless ssh_options.key?("LogLevel")
        args << "-oPort=#{port}" unless port == 22
        ssh_options.each_pair { |key, value| args << "-o#{key}=#{value}" }
        args << "-b"
        args << "-"
        # Stop sftp from treating the destination as an option.
        args << "--"
        # Without a username, sftp uses the one from the ssh config, or the current user.
        args << (username ? "#{username}@#{hostname}" : hostname)
        args
      end

      def map_log_level
        level = IOStreams.logger&.level
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
    end
  end
end
