require "uri"
require "tmpdir"
module IOStreams
  module Utils
    MAX_TEMP_FILE_NAME_ATTEMPTS = 5

    # Returns [true|false] whether the exception is a failure to look up a host name that does not resolve, such as a
    # mistyped host, so that the same request cannot succeed later. A temporary failure of name resolution
    # (`Socket::EAI_AGAIN`), which is how a DNS outage, or a network without DNS, is reported on Linux, is not.
    #
    # Ruby 3.2 does not have `Socket::ResolutionError`, so its `SocketError` is never an unknown host.
    def self.unknown_host?(exception)
      return false unless defined?(::Socket::ResolutionError) && exception.is_a?(::Socket::ResolutionError)

      exception.error_code != ::Socket::EAI_AGAIN
    end

    # Lazy load dependent gem so that it remains a soft dependency.
    def self.load_soft_dependency(gem_name, stream_type, require_name = gem_name)
      require require_name
    rescue LoadError => e
      raise(LoadError, "Please install the gem '#{gem_name}' to support #{stream_type}. #{e.message}")
    end

    # Returns [String] the url with the path `/` when it has no path, such as `sftp://host` or `https://host?a=1`,
    # so that the root of a host is always written the same way, like the root of an S3 bucket, `s3://bucket/`.
    def self.root_url(url)
      url.sub(%r{\A([^:/]+://[^/?#]*)(?=[?#]|\z)}, "\\1/")
    end

    # Helper method: Returns [true|false] if a value is blank?
    def self.blank?(value)
      return true if value.nil?
      return value !~ /\S/ if value.is_a?(String)

      value.respond_to?(:empty?) ? value.empty? : !value
    end

    # Returns [Array<String>] the extensions of the file name, in lower case, for example `["csv", "gz"]` for `"Data.CSV.gz"`.
    # The name of the file before the first `.` is not an extension, so a file named `gz` has no extensions.
    def self.file_name_extensions(file_name)
      parts = ::File.basename(file_name.to_s).sub(/\A\.+/, "").split(".")
      parts.shift
      parts.map(&:downcase)
    end

    # Yields the path to a temporary file_name.
    #
    # The file is not created, and is deleted upon completion if present.
    #
    # Only the name is chosen within `Dir::Tmpname.create`, which retries whenever its block raises
    # `Errno::EEXIST`, so that the supplied block is never run again when it raises `Errno::EEXIST` itself.
    def self.temp_file_name(basename, extension = "")
      file_name = ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir,
                                        max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        raise(Errno::EEXIST, tmpname) if ::File.exist?(tmpname) || ::File.symlink?(tmpname)
      end

      begin
        yield(file_name)
      ensure
        ::FileUtils.rm_f(file_name)
      end
    end

    # Returns [String] the absolute name of the local file that the IO reads, so that a reader that only works on
    # files, such as zip, can open the file itself instead of a temp copy of it.
    #
    # Only when the IO is a regular file at its start, and its name still refers to it, which for example a
    # relative name no longer does after the current directory changes.
    # Returns nil for any other IO, such as a pipe, a socket or a StringIO.
    #
    # The name is absolute so that it still refers to the file when the current directory changes before the
    # reader opens it.
    def self.local_file_name(io)
      return unless io.is_a?(::File) && !io.closed? && io.path

      name = ::File.absolute_path(io.path)
      name if io.stat.file? && io.pos.zero? && ::File.identical?(io, name)
    rescue SystemCallError
      nil
    end

    # Yields the name of a new, empty temporary file that only the current user can read or write.
    #
    # The file is created exclusively, so that an existing file, or a link planted in a shared
    # temp directory, is never written to. Only a name collision when creating the file is retried,
    # and the file is only deleted once it was created here, so that another process's file is never removed.
    #
    # Parameters:
    #   purpose: [String]
    #     What the file holds, such as "the download of s3://bucket/a.csv", which is logged at debug level
    #     via `IOStreams.logger` when the file is created. Its size is logged when it is deleted.
    #
    # Returns the value from the block.
    def self.private_temp_file(basename, extension = "", purpose:)
      file_name = ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir,
                                        max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        ::File.open(tmpname, ::File::WRONLY | ::File::CREAT | ::File::EXCL, 0o600, &:close)
      end
      IOStreams.logger&.debug { "Created temp file #{file_name} for #{purpose}" }

      begin
        yield(file_name)
      ensure
        IOStreams.logger&.debug { "Deleting temp file #{file_name}, which held #{::File.size?(file_name).to_i} bytes" }
        ::FileUtils.rm_f(file_name)
      end
    end

    class URI
      attr_reader :scheme, :hostname, :path, :user, :password, :port, :query

      def initialize(url)
        url       = url.gsub(" ", "%20")
        uri       = ::URI.parse(url)
        @scheme   = uri.scheme
        @hostname = uri.hostname
        # Unlike a query string, `+` in a path is not a space.
        @path     = ::URI.decode_uri_component(uri.path)
        @user     = uri.user
        @password = uri.password
        @port     = uri.port
        return unless uri.query

        @query = {}
        ::URI.decode_www_form(uri.query).each { |key, value| @query[key] = value }
      end
    end
  end
end
