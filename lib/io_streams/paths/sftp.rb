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
        attr_accessor :sshpass_bin, :sftp_bin
      end

      @sftp_bin    = "sftp"
      @sshpass_bin = "sshpass"

      # The environment variable from which `sshpass -e` reads the password.
      SSHPASS_ENV = "SSHPASS".freeze

      autoload :NetSSH, "io_streams/paths/sftp/net_ssh"

      attr_reader :hostname, :username, :ssh_options, :url, :port

      # The password, and the private key supplied as the ssh option `IdentityKey`, see IOStreams::Path.redact_options.
      def self.sensitive_option_names = %i[password identity_key]

      # Returns [String|nil] the deprecation warning for an SFTP url without a path, such as `sftp://host`, which
      # IOStreams v3.0 reads as `sftp://host/`, the root directory, see `IOStreams::Path.name_deprecation`, while this
      # version lists the login directory for it, see #each_child.
      def self.name_deprecation(url)
        return unless url_without_path?(url)

        "an SFTP url without a path, such as sftp://host, is deprecated, since v3.0 reads it as sftp://host/, the " \
          "root directory, which changes its #to_s and #path, and what #each_child lists: supply the url with the /, " \
          "which v2.2 reads the same way"
      end

      # Stream to a remote file over sftp.
      #
      # url: [String]
      #   "sftp://<host_name>/<file_name>"
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
        # A String, so that a password read from configuration as a number, such as from YAML, is the same password.
        @password = (password || uri.password)&.to_s
        @port     = uri.port || 22
        # Not Ruby 2.5 yet: transform_keys(&:to_s)
        @ssh_options = {}
        ssh_options.each_pair { |key, value| @ssh_options[key.to_s] = value }
        validate_username!

        super(uri.path)
        warn_unusable_url(uri)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def to_s
        url
      end

      # Returns [String] the url without the user name, password, query or fragment, which can hold credentials.
      def display_name
        url.sub(%r{\A([^:/]+://)[^/?#]*@}, "\\1").sub(/[?#].*\z/m, "")
      end

      # Note that mkdir is delayed and only executed when the file write is performed.
      def mkdir
        @mkdir = true
        self
      end

      # TODO: Add #copy_from shortcut to detect when a file is supplied that does not require conversion.

      # Search for files on the remote sftp server that match the provided pattern, within this path.
      # When the url does not include a path, for example `sftp://sftp.example.org`, it searches
      # the login directory.
      #
      # The pattern matching works like Net::SFTP::Operations::Dir.glob and Dir.glob
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
      def each_child(pattern = "*", case_sensitive: true, directories: false, hidden: false)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        authorize!
        Utils.load_soft_dependency("net-sftp", "SFTP glob capability", "net/sftp") unless defined?(Net::SFTP)

        flags = ::File::FNM_EXTGLOB
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden

        NetSSH.options(ssh_options, port: port, password: password) do |options|
          Net::SFTP.start(hostname, username, options) do |sftp|
            # Without a path in the url, list the login directory.
            sftp.dir.glob(path.empty? ? "." : path, pattern, flags) do |entry|
              next if !directories && !entry.file?
              next unless listed_name?(entry.name)

              child = child_path(entry.name)
              yield(child, entry.attributes.attributes) if allowed_child?(child)
            end
          end
        end
        nil
      end

      protected

      attr_writer :url

      private

      attr_reader :password

      # Returns [true|false] whether the name, relative to this path, of an entry that the server listed names a file or
      # directory within this path, logging it when it does not. Net::SFTP joins the names that the server sends, so
      # a hostile server can list an entry such as `../outside.csv`, which `#each_child` skips, see
      # `IOStreams::Utils::PathName.descendant?`.
      def listed_name?(name)
        return true if Utils::PathName.descendant?(name)

        IOStreams.logger&.warn(
          "Skipping the entry #{name.inspect} that the SFTP server listed in #{path.inspect}, since it is not the name " \
          "of a file or directory within it"
        )
        false
      end

      # Returns [String] the host, port and path, which is compared against the allowed paths.
      # `.` and `..` are resolved the way the sftp server resolves them.
      def allowed_location
        "sftp://#{hostname.to_s.downcase}:#{port}#{normalize_path(path)}".chomp("/")
      end

      # Reports a deprecation warning for each part of the url that this path cannot use, which IOStreams 3.0 raises
      # ArgumentError for when the path is created, so that a mistake in a configured url is reported wherever the
      # code runs: a url without a host, a query, whose ssh options are ignored, and a fragment, which an unencoded `#`
      # starts, and which is not part of the name. Each warning names the url without its user name, password, query or
      # fragment, see #display_name.
      def warn_unusable_url(uri)
        warn_url("it names no host, name one, such as 'sftp://example.org#{path}'") if uri.hostname.to_s.empty?
        if uri.query
          warn_url("its query is ignored, supply ssh options with ssh_options:, and percent-encode a '?' in a name as " \
                   "'%3F'")
        end
        return unless uri.fragment

        warn_url("it has a fragment, which a '#' starts, and which is not part of the name, percent-encode a '#' in a " \
                 "name as '%23'")
      end

      # Reports that the url of this path is deprecated, since IOStreams 3.0 raises ArgumentError for it, for the
      # supplied reason.
      def warn_url(reason)
        Deprecation.warn("the SFTP url #{display_name.inspect} is deprecated, since #{reason}")
      end

      # Usernames are passed to the `sftp` executable, so reject values that it could treat as options.
      def validate_username!
        return if username.nil?
        return unless username.to_s.start_with?("-") || username.to_s.match?(/[[:cntrl:]]/)

        raise(ArgumentError, "Invalid SFTP username: it cannot start with '-' or contain control characters")
      end

      # Raises ArgumentError for a password that sshpass cannot give the sftp program, which reading and writing run:
      # sshpass types it at the password prompt as one line, so a line feed or carriage return would end it early, and
      # an environment variable cannot hold a NUL. Checked before the file is read or written, rather than when the path
      # is created, since net-sftp, which lists files, takes any password. The message never includes it.
      def check_sshpass_password!
        return unless password&.b&.match?(/[\n\r\0]/n)

        raise(ArgumentError, "Invalid SFTP password for the sftp program: it cannot contain a line break or a NUL")
      end

      # Set the path directly rather than parsing it as part of a URL, since a file name can contain
      # characters such as `?`, `#`, `+` or `%` that a URL parser would treat as a query or as escapes.
      #
      # The supplied name is relative to this path, or to the login directory when this url has no path.
      def child_path(name)
        server     = port == 22 ? "sftp://#{hostname}" : "sftp://#{hostname}:#{port}"
        child      = self.class.new(server, username: username, password: password, ssh_options: ssh_options)
        child.replace_path((path.empty? ? "/#{name}" : Utils::PathName.join(path, name)).freeze)
        child.url = "#{server}#{child.path}"
        child
      end

      def stream_reader(&block)
        check_sshpass_password!
        Utils.private_temp_file("iostreams-sftp-reader") do |file_name|
          sftp_download(path, file_name)
          ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
        end
      end

      def stream_writer(&block)
        check_sshpass_password!
        Utils.private_temp_file("iostreams-sftp-writer") do |file_name|
          ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }
          sftp_upload(file_name, path)
          ::File.size(file_name)
        end
      end

      # Use the sftp executable to download to a local file, via sshpass when a password is supplied.
      #
      # The input of sftp holds only the batch commands, since sftp runs each line of it, including a `!command`, which
      # runs in the local shell. So sshpass reads the password from its environment (`-e`), see #sftp_env, never from
      # that input, and never from its arguments, which other users can see in the process list.
      def sftp_download(remote_file_name, local_file_name)
        with_sftp_args do |args|
          Open3.popen2e(sftp_env, *args) do |writer, reader, waith_thr|
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
          Open3.popen2e(sftp_env, *args) do |writer, reader, waith_thr|
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

      # The password is removed from the output before it is included in the error, should sftp or ssh ever echo it.
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

      # Returns [Hash] the environment of the program that #sftp_args runs: the password for sshpass, when one is
      # supplied. sshpass can pass it on to the sftp and ssh processes that it starts, such as a ProxyCommand, so it is
      # in the environment of those processes too, which only the same user and root can read.
      def sftp_env
        password ? {SSHPASS_ENV => password} : {}
      end

      def sftp_args(ssh_options)
        # sshpass is only needed to supply the password to sftp.
        # It reads the password from the environment, see #sftp_env.
        args = password ? [self.class.sshpass_bin, "-e", self.class.sftp_bin] : [self.class.sftp_bin]
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
        args << "#{username}@#{hostname}"
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

require_relative "sftp/deprecated_settings"
