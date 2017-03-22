module IOStreams
  # Example:
  #   IOStreams::SFTP::Reader.open(
  #     'file.txt',
  #     user:     'jbloggs',
  #     password: 'secret',
  #     host:     'example.org'
  #   ) do |input|
  #     puts input.read
  #   end
  module SFTP
    class Reader
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      # Stream to a remote file over sftp.
      #
      # file_name: [String]
      #   Name of file to read from.
      #
      # user: [String]
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
      # binary [true|false]
      #   Whether to write in binary mode
      #   Default: true
      #
      # options: [Hash]
      #   Any options supported by Net::SSH.start
      #
      # Note:
      # - Net::SFTP::StatusException means the file could not be read
      def self.open(file_name, user:, password:, host:, port: 22, binary: true, options: {}, &block)
        raise(NotImplementedError, 'Can only SFTP directly to a file name, not another stream.') if IOStreams.writer_stream?(file_name)

        begin
          require 'net/sftp' unless defined?(Net::SFTP)
        rescue LoadError => e
          raise(LoadError, "Please install the 'net-sftp' gem for SFTP streaming support. #{e.message}")
        end

        options                = options.dup
        options[:logger]       ||= self.logger if defined?(SemanticLogger)
        options[:port]         ||= 22
        options[:max_pkt_size] ||= 65536
        options[:password]     = password
        options[:port]         = port
        mode                   = binary ? 'rb' : 'r'

        result = nil
        Net::SFTP.start(host, user, options) do |sftp|
          result = sftp.file.open(file_name, mode, &block)
        end
        result
      end

    end
  end
end
