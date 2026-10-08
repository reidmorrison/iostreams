require "uri"
require "tmpdir"
module IOStreams
  module Utils
    MAX_TEMP_FILE_NAME_ATTEMPTS = 5

    # Replaces the value of a sensitive option for display, see .redact_options.
    FILTERED = "[FILTERED]".freeze

    # Option names whose values are hidden as a precaution, even when they are not declared sensitive.
    # Matched against the name in lower case without `_` or `-`, see .redact_options.
    SENSITIVE_NAME = /passphrase|password|secret|token|credential|auth|apikey|privatekey/
    private_constant :SENSITIVE_NAME

    # Returns [Hash] the options with the value of each sensitive option replaced with FILTERED, so that they can be
    # displayed, for example by `#inspect`, or in a web interface.
    #
    # An option is sensitive when its name is one of the supplied `sensitive_names`, or, as a precaution, contains
    # `passphrase`, `password`, `secret`, `token`, `credential`, `auth`, `apikey` or `privatekey`. Names are compared in
    # lower case, ignoring `_` and `-`, so that `:identity_key` matches the ssh option "IdentityKey", and the header
    # "X-Api-Key" contains `apikey`. The options in a Hash value, such as `ssh_options:` or `headers:`, are redacted the
    # same way, as are those in an Array value, whether its elements are Hashes or `[name, value]` pairs.
    def self.redact_options(options, sensitive_names = [])
      redact_hash(options, sensitive_names.map { |name| normalize_option_name(name) })
    end

    # Returns [true|false] whether the exception is a failure to look up a host name that does not resolve, such as a
    # mistyped host, so that the same request cannot succeed later. A temporary failure of name resolution
    # (`Socket::EAI_AGAIN`), which is how a DNS outage, or a network without DNS, is reported on Linux, is not.
    #
    # Ruby 3.2 does not have `Socket::ResolutionError`, so its `SocketError` is never an unknown host.
    def self.unknown_host?(exception)
      return false unless defined?(::Socket::ResolutionError) && exception.is_a?(::Socket::ResolutionError)

      exception.error_code != ::Socket::EAI_AGAIN
    end

    def self.redact_hash(options, sensitive)
      options.to_h { |name, value| [name, redact_option(name, value, sensitive)] }
    end
    private_class_method :redact_hash

    # Returns the value of the named option for display, see .redact_options.
    def self.redact_option(name, value, sensitive)
      key = normalize_option_name(name)
      return FILTERED if sensitive.include?(key) || key.match?(SENSITIVE_NAME)

      redact_value(value, sensitive)
    end
    private_class_method :redact_option

    # Returns the value with the options within it redacted, when it is a Hash or an Array, see .redact_options.
    def self.redact_value(value, sensitive)
      case value
      when Hash
        redact_hash(value, sensitive)
      when Array
        value.map do |element|
          if element.is_a?(Array) && element.size == 2 && (element.first.is_a?(String) || element.first.is_a?(Symbol))
            [element.first, redact_option(element.first, element.last, sensitive)]
          else
            redact_value(element, sensitive)
          end
        end
      else
        value
      end
    end
    private_class_method :redact_value

    def self.normalize_option_name(name)
      name.to_s.downcase.delete("_-")
    end
    private_class_method :normalize_option_name

    # Lazy load dependent gem so that it remains a soft dependency.
    def self.load_soft_dependency(gem_name, stream_type, require_name = gem_name)
      require require_name
    rescue LoadError => e
      raise(LoadError, "Please install the gem '#{gem_name}' to support #{stream_type}. #{e.message}")
    end

    # Returns [true|false] whether the soft dependency is installed, loading it when it is, see .load_soft_dependency.
    #
    # Raises LoadError when the gem is installed but cannot be loaded, such as when a gem that it requires is missing,
    # so that a broken installation is reported, rather than treated as a gem that is not installed.
    def self.soft_dependency_installed?(gem_name, stream_type, require_name = gem_name)
      load_soft_dependency(gem_name, stream_type, require_name)
      true
    rescue LoadError => e
      raise unless e.cause.is_a?(LoadError) && e.cause.path == require_name

      false
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

    # Yields the name of a new, empty temporary file that only the current user can read or write.
    #
    # The file is created exclusively, so that an existing file, or a link planted in a shared
    # temp directory, is never written to. Only a name collision when creating the file is retried,
    # and the file is only deleted once it was created here, so that another process's file is never removed.
    #
    # Returns the value from the block.
    def self.private_temp_file(basename, extension = "")
      file_name = ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir,
                                        max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        ::File.open(tmpname, ::File::WRONLY | ::File::CREAT | ::File::EXCL, 0o600, &:close)
      end

      begin
        yield(file_name)
      ensure
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
