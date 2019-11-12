require 'open3'

module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      class << self
        attr_accessor :sshpass_bin, :sftp_bin, :sshpass_wait_seconds
        @sftp_bin             = 'sftp'
        @sshpass_bin          = 'sshpass'
        @sshpass_wait_seconds = 5
      end

      attr_reader :hostname, :username, :ssh_options, :url, :port, :ruby

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
      # host: [String]
      #   Name of the host to connect to.
      #
      # port: [Integer]
      #   Port to connect to at the above host.
      #
      # ruby: [true|false]
      #   Use the pure Ruby sftp library to transfer the files.
      #   With very large files it is faster to use the command line sftp and sshpass executables.
      #   Default: false
      #
      # **ssh_options
      #   When `ruby: true`:
      #     Any other options supported by Net::SSH.start
      #   When `ruby: false`:
      #     Any other options supported by ssh_config.
      #     `man ssh_config` to see all available options.
      #
      # Examples:
      #
      # # Display the contents of a remote file
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", password: "OpenSesame").reader do |io|
      #     puts io.read
      #   end
      #
      # # Full url showing all the optional elements that can be set via the url:
      #   sftp://username:password@hostname:22/path/file_name
      #
      # # Display the contents of a remote file, supplying the username and password in the url
      #   IOStreams.path("sftp://jack:OpenSesame@test.com:22/path/file_name.csv").reader do |io|
      #     puts io.read
      #   end
      #
      # # Use the faster sftp executable to read the file to a local tempfile for further reading:
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", password: "OpenSesame", ruby: false).reader do |io|
      #     puts io.read
      #   end
      #
      # # When using the sftp executable use an identity file instead of a password to authenticate:
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", ruby: false, IdentityFile: "~/.ssh/private_key").reader do |io|
      #     puts io.read
      #   end
      #
      # # When using the sftp executable, disable Public Key Authentication:
      #   IOStreams.path("sftp://test.com/path/file_name.csv", username: "jack", password: "OpenSesame", ruby: false, PubkeyAuthentication: "no").reader do |io|
      #     puts io.read
      #   end
      #
      # "sftp://jack@test.com/path/file_name.csv?IdentityFile='~/.ssh/private_key'"
      # "sftp://test.com/path/file_name.csv", username: "jack", ruby: false, IdentityFile: "~/.ssh/private_key"
      def initialize(url, username: nil, password: nil, port: nil, ruby: true, **ssh_options)
        Utils.load_dependency('net-sftp', 'net/sftp') unless defined?(Net::SFTP)

        uri = URI.parse(url)
        raise(ArgumentError, "Invalid URL. Required Format: 'sftp://<host_name>/<file_name>'") unless uri.scheme == 'sftp'

        @hostname              = uri.hostname
        @mkdir                 = false
        @username              = username || uri.user
        @url                   = url
        @password              = password || uri.password
        @port                  = port || uri.port || 22
        @ssh_options           = ssh_options

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
        result = nil
        if ruby
          Net::SFTP.start(hostname, username, build_ssh_options) { |sftp| result = sftp.file.open(path, 'rb', &block) }
        else
          IOStreams.temp_file("sftp-download") do |temp_file|
            sftp_download(path, temp_file.to_s)
            temp_file.reader(&block)
          end
        end
        result
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
        result = nil
        Net::SFTP.start(hostname, username, build_ssh_options) do |sftp|
          sftp.session.exec!("mkdir -p '#{::File.dirname(path)}'") if mkdir
          result = sftp.file.open(path, 'wb', &block)
        end
        result
      end

      # Search for files on the remote sftp server that match the provided pattern.
      #
      # The pattern matching works like Net::SFTP::Operations::Dir.glob and Dir.glob
      # Each child also returns attributes that contain the file size, ownership, file dates and other details.
      #
      # Example Code:
      # IOStreams.
      #   path("sftp://#{hostname}", username: username, password: password).
      #   each_child('**/*.{csv,txt}', directories: false) do |input,attributes|
      #     puts "#{input.to_s} #{attributes}"
      #   end
      #
      # Example Output:
      # sftp://sample.server.com/a/b/c/test.txt {:type=>1, :size=>37, :owner=>"test_owner", :group=>"test_group", :permissions=>420, :atime=>1572378136, :mtime=>1572378136, :link_count=>1, :extended=>{}}
      def each_child(pattern = "*", case_sensitive: true, directories: false, hidden: false)
        flags = ::File::FNM_EXTGLOB # always support matching like *.{csv,txt}
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden
        Net::SFTP.start(hostname, username, options) do |sftp|
          sftp.dir.glob(".", pattern, flags) do |path|
            next if !directories && !path.file?
            yield(self.class.new("sftp://#{hostname}/#{path.name}", username: username, password: options[:password]), path.attributes.attributes)
          end
        end
        nil
      end

      private

      attr_reader :password

      # Use sftp and sshpass executables to download to a local file
      def sftp_download(remote_file_name, local_file_name)
        Open3.popen2e(*sftp_args) do |writer, reader, waith_thr|
          writer.puts password
          # Give time for password to be processed and stdin to be passed to sftp process.
          sleep self.class.sshpass_wait_seconds
          writer.puts "get #{remote_file_name} #{local_file_name}"
          writer.puts 'bye'
          writer.close
          out = reader.read.chomp
          raise(Errors::CommunicationsFailure, "Failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}") unless waith_thr.value.success?
          out
        end
      end

      def sftp_upload(local_file_name, remote_file_name)
        Open3.popen2e(*sftp_args) do |writer, reader, waith_thr|
          writer.puts(password) if password
          # Give time for password to be processed and stdin to be passed to sftp process.
          sleep self.class.sshpass_wait_seconds
          writer.puts "put #{local_file_name.inspect} #{remote_file_name.inspect}"
          writer.puts 'bye'
          writer.close
          out = reader.read.chomp
          raise(Errors::CommunicationsFailure, "Failed calling #{self.class.sftp_bin} via #{self.class.sshpass_bin}: #{out}") unless waith_thr.value.success?
          out
        end
      end

      def sftp_args
        args = [self.class.sshpass_bin, self.class.sftp_bin, '-oBatchMode=no']
        ssh_options.each_pair { |key, value| args << "-o#{key}=#{value}" }
        args << '-b'
        args << '-'
        args << "#{username}@#{hostname}"
        args
      end

      def build_ssh_options
        options                = ssh_options.dup
        options[:logger]       ||= self.logger if defined?(SemanticLogger)
        options[:port]         ||= @port
        options[:max_pkt_size] ||= 65_536
        options[:password]     ||= @password
        options
      end
    end
  end
end
