module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      attr_reader :hostname, :username, :create_path, :options, :url

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
      # **args
      #   Any other options supported by Net::SSH.start
      #
      # Examples:
      #
      # # Sample URL
      #   sftp://hostname/path/file_name
      #
      # # Full url showing all the optional elements that can be set via the url:
      #   sftp://username:password@hostname:22/path/file_name
      def initialize(url, username:, password:, port: nil, max_pkt_size: 65_536, logger: nil, create_path: false, **args)
        Utils.load_dependency('net-sftp', 'net/sftp') unless defined?(Net::SFTP)

        uri = URI.parse(url)
        raise(ArgumentError, "Invalid URL. Required Format: 'sftp://<host_name>/<file_name>'") unless uri.scheme == 'sftp'

        @hostname              = uri.hostname
        @mkdir                 = false
        @username              = username || uri.user
        @create_path           = create_path
        @url                   = url

        logger                 ||= self.logger if defined?(SemanticLogger)
        options                = args.dup
        options[:logger]       = logger
        options[:port]         = port || uri.port || 22
        options[:max_pkt_size] = max_pkt_size
        options[:password]     = password || uri.password
        @options               = options
        super(uri.path)
      end

      def to_s
        url
      end

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
        Net::SFTP.start(hostname, username, options) do |sftp|
          result = sftp.file.open(path, 'rb', &block)
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
        Net::SFTP.start(hostname, username, options) do |sftp|
          sftp.session.exec!("mkdir -p '#{::File.dirname(path)}'") if create_path
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

    end
  end
end
