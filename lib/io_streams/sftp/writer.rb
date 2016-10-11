module IOStreams
  # Example:
  #   IOStreams::SFTP::Writer.open('file.txt',
  #     user:     'jbloggs',
  #     password: 'secret',
  #     host:     'example.org',
  #     options: {compression: false}
  #   ) do |output|
  #       output.write('Hello World')
  #   end
  module SFTP
    class Writer
      include SemanticLogger::Loggable if defined?(SemanticLogger)

      # Stream to a remote file over sftp.
      #
      # file_name: [String]
      #   Name of file to write to.
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
      # mkdir [true|false]
      #   Whether to create the output directory on the target system before writing the file.
      #   The path is created recursively if any portions of the path that are missing.
      #   Default: false
      #
      # binary [true|false]
      #   Whether to write in binary mode
      #   Default: true
      #
      # options: [Hash]
      #   Any options supported by Net::SSH.start
      def self.open(file_name, user:, password:, host:, port: 22, mkdir: false, binary: true, options: {}, &block)
        raise(NotImplementedError, 'Can only SFTP directly to a file name, not another stream.') if IOStreams.writer_stream?(file_name)

        begin
          require 'net/sftp' unless defined?(Net::SFTP)
        rescue LoadError => e
          raise(LoadError, "Please install the 'net-sftp' gem for SFTP streaming support. #{e.message}")
        end

        options                = options.dup
        options[:logger]       ||= logger if defined?(SemanticLogger)
        options[:port]         ||= 22
        options[:max_pkt_size] ||= 65536
        options[:password]     = password
        options[:port]         = port
        mode                   = binary ? 'wb' : 'w'

        Net::SFTP.start(host, user, options) do |sftp|
          sftp.session.exec!("mkdir -p '#{::File.dirname(file_name)}'") if mkdir
          sftp.file.open(file_name, mode, &block)
        end
      end

    end
  end
end
