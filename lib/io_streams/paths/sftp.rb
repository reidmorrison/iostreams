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
    # - raises IOStreams::Errors::CommunicationsFailure when the file could not be read, tagged with the kind of
    #   failure when it is known, such as IOStreams::Errors::NotFound, see IOStreams::Errors::StorageError.
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

      autoload :Failure, "io_streams/paths/sftp/failure"
      autoload :Listing, "io_streams/paths/sftp/listing"
      autoload :NetSSH, "io_streams/paths/sftp/net_ssh"

      attr_reader :hostname, :username, :ssh_options, :url, :port

      # The password, and the private key supplied as the ssh option `IdentityKey`, see IOStreams::Path.redact_options.
      def self.sensitive_option_names = %i[password identity_key]

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
      #     Supply them with the `username:` and `password:` arguments instead,
      #     and log `#display_name`, which never includes them.
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
        @url      = Utils.root_url(url)
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
        remove("SFTP delete capability") { |sftp| sftp.rmdir!(remote_path) }
      end

      # When path is a directory, deletes this directory and everything within it.
      # When path is a file, deletes this file.
      #
      # Returns self
      #
      # Notes:
      # * No error is raised if the file or directory is not present.
      # * A symbolic link is deleted, not the file or directory that it refers to.
      def delete_all
        remove("SFTP delete_all capability") { |sftp| Listing.remove_tree(sftp, remote_path) }
      end

      # Returns [true|false] whether the file or directory exists.
      def exist?
        !remote_attributes("SFTP exist? capability").nil?
      end

      # Returns [Integer] the size of the file.
      #
      # Raises [IOStreams::Errors::NotFound] when the file does not exist, see `#size?`.
      def size
        with_net_sftp("SFTP size capability") { |sftp| sftp.stat!(remote_path).size }
      end

      def mtime
        with_net_sftp("SFTP mtime capability") { |sftp| Time.at(sftp.stat!(remote_path).mtime) }
      end

      def file?
        remote_attributes("SFTP file? capability")&.file? || false
      end

      def directory?
        remote_attributes("SFTP directory? capability")&.directory? || false
      end

      def empty?
        with_net_sftp("SFTP empty? capability") do |sftp|
          attributes = Listing.remote_attributes(sftp, remote_path)
          if attributes&.directory?
            sftp.dir.entries(remote_path).all? { |entry| %w[. ..].include?(entry.name) }
          else
            size = attributes&.size
            !size.nil? && size.zero?
          end
        end
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

        matcher   = Matcher.new(pattern, case_sensitive: case_sensitive, hidden: hidden)
        directory = matcher.directory.empty? ? self : child_path(matcher.directory)
        with_net_sftp("SFTP glob capability") do |sftp|
          if matcher.exact?
            # When the pattern is an exact file name without any pattern characters
            child      = child_path(matcher.pattern, directory.path)
            attributes = Listing.remote_attributes(sftp, child.remote_path)
            found      = attributes && (attributes.file? || (directories && attributes.directory?))
            yield(child, attributes.attributes) if found && allowed_child?(child)
          else
            Listing.each(sftp, directory.remote_path, matcher, directories: directories) do |name, attributes|
              child = child_path(name, directory.path)
              yield(child, attributes) if allowed_child?(child)
            end
          end
        end
        nil
      end

      # Returns [String] the url without the user name, password, or query, which can hold ssh options such as a key.
      def display_name
        url.sub(%r{\A([^:/]+://)[^/?#]*@}, "\\1").sub(/[?#].*\z/m, "")
      end

      protected

      # Paths on the same host and port are in the same store, see `IOStreams::Path#same_store?`.
      def store = [hostname.to_s.downcase, port]

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

      # Connects to the server with Net::SFTP, which supplies the named capability, and yields the session.
      # Returns the result of the block.
      def with_net_sftp(capability)
        authorize!
        Utils.load_soft_dependency("net-sftp", capability, "net/sftp") unless defined?(Net::SFTP)

        result    = nil
        connected = false
        tag_failure do
          NetSSH.options(ssh_options, port: port, password: password) do |options|
            Net::SFTP.start(hostname, username, options) do |sftp|
              connected = true
              result    = yield(sftp)
            end
          end
        rescue *Failure::CONNECTION_ERRORS => e
          # Once connected, the same exception can be raised by the block supplied by the caller, such as `#each_child`.
          # A host that does not resolve is not unavailable, since the same request cannot succeed later.
          raise if connected || Utils.unknown_host?(e)

          raise(Errors::Unavailable.tag(e, display_name))
        end
        result
      end

      # Returns [Module] the kind of failure that an exception raised by net-sftp, or net-ssh, means,
      # see `Failure.kind`.
      def failure_kind(exception)
        Failure.kind(exception)
      end

      # Deletes this path when it is a file or a symbolic link, otherwise yields the session to delete the directory.
      # Does nothing when it does not exist. Returns self.
      def remove(capability)
        with_net_sftp(capability) do |sftp|
          sftp.lstat!(remote_path).directory? ? yield(sftp) : sftp.remove!(remote_path)
        rescue Net::SFTP::StatusException => e
          raise unless Listing::NOT_FOUND.include?(e.code)
        end
        self
      end

      # Returns the attributes of this path on the server, or nil when it does not exist.
      def remote_attributes(capability)
        with_net_sftp(capability) { |sftp| Listing.remote_attributes(sftp, remote_path) }
      end

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
            raise_failure("Download", out, waith_thr.value) unless waith_thr.value.success?

            out
          rescue Errno::EPIPE
            out = begin
              reader.read.chomp
            rescue StandardError
              nil
            end
            raise_failure("Download", out, waith_thr.value)
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
            raise_failure("Upload", out, waith_thr.value) unless waith_thr.value.success?

            out
          rescue Errno::EPIPE
            out = begin
              reader.read.chomp
            rescue StandardError
              nil
            end
            raise_failure("Upload", out, waith_thr.value)
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

      # Raises [IOStreams::Errors::CommunicationsFailure] with the output of the sftp program, tagged with the kind of
      # failure that the output and the exit status mean, see `Failure.output_kind`.
      #
      # When the server does not prompt for a password, sftp reads the password line as a command
      # and echoes it in its output, so remove it before the output is included in the error.
      def raise_failure(action, out, status = nil)
        out   = out.gsub(password.to_s, "[FILTERED]") if out && !password.to_s.empty?
        error = Errors::CommunicationsFailure.new(
          "#{action} failed calling #{self.class.sftp_bin}#{" via #{self.class.sshpass_bin}" if password}: #{out}"
        )
        kind = Failure.output_kind(out, status, sshpass: !password.nil?)
        raise(kind ? kind.tag(error, display_name) : error)
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
