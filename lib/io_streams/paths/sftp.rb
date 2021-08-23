require "open3"

module IOStreams
  module Paths
    # Read a file from a remote sftp server.
    #
    # Example:
    #   IOStreams.
    #     path("sftp://example.org/path/file.txt", username: "jbloggs", password: "secret", compression: false).
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
    #     path("sftp://example.org/path/file.txt", username: "jbloggs", password: "secret", compression: false).
    #     writer do |output|
    #       output.write('Hello World')
    #     end
    class SFTP < IOStreams::Path
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      class << self
        attr_accessor :sshpass_bin, :sftp_bin, :sshpass_wait_seconds, :before_password_wait_seconds
      end

      @sftp_bin                     = "sftp"
      @sshpass_bin                  = "sshpass"
      @before_password_wait_seconds = 2
      @sshpass_wait_seconds         = 5

      attr_reader :hostname, :username, :ssh_options, :url, :port

      # Stream to a remote file over sftp.
      #
      # url: [String]
      #   "sftp://<host_name>/<file_name>"
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
        @ssh_options.merge(uri.query) if uri.query

        super(uri.path)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def to_s
        url
      end

      # Note that mkdir is delayed and only executed when the file write is performed.
      def mkdir
        @mkdir = true
        self
      end

      # TODO: Add #copy_from shortcut to detect when a file is supplied that does not require conversion.

      # Search for files on the remote sftp server that match the provided pattern.
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
      # sftp://sftp.example.org/a/b/c/test.txt {:type=>1, :size=>37, :owner=>"test_owner", :group=>"test_group",
      #   :permissions=>420, :atime=>1572378136, :mtime=>1572378136, :link_count=>1, :extended=>{}}
      def each_child(pattern = "*", case_sensitive: true, directories: false, hidden: false)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        Utils.load_soft_dependency("net-sftp", "SFTP glob capability", "net/sftp") unless defined?(Net::SFTP)

        flags = ::File::FNM_EXTGLOB
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden

        Net::SFTP.start(hostname, username, build_ssh_options) do |sftp|
          sftp.dir.glob(".", pattern, flags) do |path|
            next if !directories && !path.file?

            new_path = self.class.new("sftp://#{hostname}/#{path.name}", username: username, password: password, **ssh_options)
            yield(new_path, path.attributes.attributes)
          end
        end
        nil
      end

      private

      attr_reader :password

      def stream_reader(&block)
        IOStreams.temp_file("iostreams-sftp-reader") do |temp_file|
          sftp_download(path, temp_file.to_s)
          ::File.open(temp_file.to_s, "rb") { |io| builder.reader(io, &block) }
        end
      end

      def stream_writer(&block)
        IOStreams.temp_file("iostreams-sftp-writer") do |temp_file|
          ::File.open(temp_file.to_s, "wb") { |io| builder.writer(io, &block) }
          sftp_upload(temp_file.to_s, path)
          temp_file.size
        end
      end

      # Use sftp and sshpass executables to download to a local file
      def sftp_download(remote_file_name, local_file_name)
        with_sftp_args do |args|
          Open3.popen2e(*args) do |writer, reader, waith_thr|
            # Give time for remote sftp server to get ready to accept the password.
            sleep self.class.before_password_wait_seconds

            writer.puts password

            # Give time for password to be processed and stdin to be passed to sftp process.
            sleep self.class.sshpass_wait_seconds

            writer.puts "get #{remote_file_name} #{local_file_name}"
            writer.puts "bye"
            writer.close
            out = reader.read.chomp
            unless waith_thr.value.success?
              raise(
                Errors::CommunicationsFailure,
                "Download failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}"
              )
            end

            out
          rescue Errno::EPIPE
            out = begin
              reader.read.chomp
            rescue StandardError
              nil
            end
            raise(
              Errors::CommunicationsFailure,
              "Download failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}"
            )
          end
        end
      end

      def sftp_upload(local_file_name, remote_file_name)
        with_sftp_args do |args|
          Open3.popen2e(*args) do |writer, reader, waith_thr|
            writer.puts(password) if password
            # Give time for password to be processed and stdin to be passed to sftp process.
            sleep self.class.sshpass_wait_seconds
            writer.puts "put #{local_file_name.inspect} #{remote_file_name.inspect}"
            writer.puts "bye"
            writer.close
            out = reader.read.chomp
            unless waith_thr.value.success?
              raise(
                Errors::CommunicationsFailure,
                "Upload failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}"
              )
            end

            out
          rescue Errno::EPIPE
            out = begin
              reader.read.chomp
            rescue StandardError
              nil
            end
            raise(
              Errors::CommunicationsFailure,
              "Upload failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}"
            )
          end
        end
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
        Utils.temp_file_name("iostreams-sftp-args", "key") do |file_name|
          # sftp requires that private key is only readable by the current user
          ::File.open(file_name, "wb", 0o600) { |io| io.write(value) }

          options[option] = file_name
          yield options
        end
      end

      def sftp_args(ssh_options)
        args = [self.class.sshpass_bin, self.class.sftp_bin]
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
        args << "#{username}@#{hostname}"
        args
      end

      def build_ssh_options
        options = ssh_options.dup
        options[:logger]       ||= logger if defined?(SemanticLogger)
        options[:port]         ||= port
        options[:max_pkt_size] ||= 65_536
        options[:password]     ||= @password
        options
      end

      def map_log_level
        return "INFO" unless defined?(SemanticLogger)

        case logger.level
        when :trace
          "DEBUG3"
        when :warn
          "ERROR"
        else
          logger.level.to_s
        end
      end
    end
  end
end
