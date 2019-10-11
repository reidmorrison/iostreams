module IOStreams
  module Paths
    class SFTP < IOStreams::Path
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      attr_reader :host, :username, :mkdir, :options

      # Stream to a remote file over sftp.
      #
      # file_name: [String]
      #   Name of file to write to.
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
      def initialize(file_name, username:, password:, host:, port: 22, max_pkt_size: 65_536, logger: nil, **args)
        Utils.load_dependency('net-sftp', 'net/sftp') unless defined?(Net::SFTP)

        logger                 ||= self.logger if defined?(SemanticLogger)
        options                = args.dup
        options[:logger]       = logger
        options[:port]         = port
        options[:max_pkt_size] = max_pkt_size
        options[:password]     = password
        @options               = options
        @mkdir                 = false
        @username              = username
        super(file_name)
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
        Net::SFTP.start(host, username, options) do |sftp|
          result = sftp.file.open(file_name, 'rb', &block)
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
        Net::SFTP.start(host, username, options) do |sftp|
          sftp.session.exec!("mkdir -p '#{::File.dirname(file_name)}'") if mkdir
          result = sftp.file.open(file_name, 'wb', &block)
        end
        result
      end
    end
  end
end
