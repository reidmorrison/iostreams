require 'open3'

module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      class << self
        attr_accessor :sshpass_bin, :sftp_bin, :sshpass_wait_seconds
      end

      @sftp_bin             = 'sftp'
      @sshpass_bin          = 'sshpass'
      @sshpass_wait_seconds = 5

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
      # **ssh_options
      #   Any other options supported by ssh_config.
      #   `man ssh_config` to see all available options.
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
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", IdentityFile: "~/.ssh/private_key").reader do |io|
      #     puts io.read
      #   end
      def initialize(url, username: nil, password: nil, ruby: true, ssh_options: {})
        uri = URI.parse(url)
        raise(ArgumentError, "Invalid URL. Required Format: 'sftp://<host_name>/<file_name>'") unless uri.scheme == 'sftp'

        @hostname = uri.hostname
        @mkdir    = false
        @username = username || uri.user
        @url      = url
        @password = password || uri.password
        @port     = uri.port || 22
        # Not Ruby 2.5 yet: transform_keys(&:to_s)
        @ssh_options = {}
        ssh_options.each_pair { |key, value| @ssh_options[key.to_s] = value }

        URI.decode_www_form(uri.query).each { |key, value| @ssh_options[key] = value } if uri.query

        super(uri.path)
      end

      def to_s
        url
      end

      # Note that mkdir is delayed and only executed when the file write is performed.
      def mkdir
        @mkdir = true
        self
      end

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
      def reader(&block)
        IOStreams.temp_file("iostreams-sftp-reader") do |temp_file|
          sftp_download(path, temp_file.to_s)
          ::File.open(temp_file.to_s, "rb") { |io| streams.reader(io, &block) }
        end
      end

      # Write to a file on a remote sftp server.
      #
      # Example:
      #   IOStreams.
      #     path("sftp://example.org/path/file.txt", username: "jbloggs", password: "secret", compression: false).
      #     writer do |output|
      #       output.write('Hello World')
      #     end
      def writer(&block)
        IOStreams.temp_file("iostreams-sftp-writer") do |temp_file|
          ::File.open(temp_file.to_s, "wb") { |io| streams.writer(io, &block) }
          sftp_upload(temp_file.to_s, path)
          temp_file.size
        end
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
      # sftp://sftp.example.org/a/b/c/test.txt {:type=>1, :size=>37, :owner=>"test_owner", :group=>"test_group", :permissions=>420, :atime=>1572378136, :mtime=>1572378136, :link_count=>1, :extended=>{}}
      def each_child(pattern = "*", case_sensitive: true, directories: false, hidden: false)
        Utils.load_soft_dependency("net-sftp", "SFTP glob capability", "net/sftp") unless defined?(Net::SFTP)

        flags = ::File::FNM_EXTGLOB
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden

        Net::SFTP.start(hostname, username, build_ssh_options) do |sftp|
          sftp.dir.glob(".", pattern, flags) do |path|
            next if !directories && !path.file?
            new_path = self.class.new("sftp://#{hostname}/#{path.name}", username: username, password: password, ruby: ruby, **ssh_options)
            yield(new_path, path.attributes.attributes)
          end
        end
        nil
      end

      private

      attr_reader :password

      # Use sftp and sshpass executables to download to a local file
      def sftp_download(remote_file_name, local_file_name)
        with_sftp_args do |args|
          Open3.popen2e(*args) do |writer, reader, waith_thr|
            begin
              writer.puts password
              # Give time for password to be processed and stdin to be passed to sftp process.
              sleep self.class.sshpass_wait_seconds
              writer.puts "get #{remote_file_name} #{local_file_name}"
              writer.puts 'bye'
              writer.close
              out = reader.read.chomp
              raise(Errors::CommunicationsFailure, "Download failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}") unless waith_thr.value.success?
              out
            rescue Errno::EPIPE
              out = reader.read.chomp rescue nil
              raise(Errors::CommunicationsFailure, "Download failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}")
            end
          end
        end
      end

      def sftp_upload(local_file_name, remote_file_name)
        with_sftp_args do |args|
          Open3.popen2e(*args) do |writer, reader, waith_thr|
            begin
              writer.puts(password) if password
              # Give time for password to be processed and stdin to be passed to sftp process.
              sleep self.class.sshpass_wait_seconds
              writer.puts "put #{local_file_name.inspect} #{remote_file_name.inspect}"
              writer.puts 'bye'
              writer.close
              out = reader.read.chomp
              raise(Errors::CommunicationsFailure, "Upload failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}") unless waith_thr.value.success?
              out
            rescue Errno::EPIPE
              out = reader.read.chomp rescue nil
              raise(Errors::CommunicationsFailure, "Upload failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}")
            end
          end
        end
      end

      def with_sftp_args
        return yield sftp_args(ssh_options) unless ssh_options.key?('IdentityKey')

        Utils.temp_file_name('iostreams-sftp-args', 'key') do |file_name|
          options = ssh_options.dup
          key     = options.delete('IdentityKey')
          # sftp requires that private key is only readable by the current user
          ::File.open(file_name, 'wb', 0600) { |io| io.write(key) }

          options['IdentityFile'] = file_name
          yield sftp_args(options)
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
        args << "-oIdentitiesOnly=yes" if ssh_options.key?('IdentityFile')
        # Default is ask, but this is non-interactive so make the default fail without asking.
        args << "-oStrictHostKeyChecking=yes" unless ssh_options.key?('StrictHostKeyChecking')
        args << "-oLogLevel=#{map_log_level}" unless ssh_options.key?('LogLevel')
        args << "-oPort=#{port}" unless port == 22
        ssh_options.each_pair { |key, value| args << "-o#{key}=#{value}" }
        args << '-b'
        args << '-'
        args << "#{username}@#{hostname}"
        args
      end

      def build_ssh_options
        options                = ssh_options.dup
        options[:logger]       ||= self.logger if defined?(SemanticLogger)
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
