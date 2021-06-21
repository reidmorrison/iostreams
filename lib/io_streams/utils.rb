require "uri"
require "tmpdir"
module IOStreams
  module Utils
    MAX_TEMP_FILE_NAME_ATTEMPTS = 5

    # Lazy load dependent gem so that it remains a soft dependency.
    def self.load_soft_dependency(gem_name, stream_type, require_name = gem_name)
      require require_name
    rescue LoadError => e
      raise(LoadError, "Please install the gem '#{gem_name}' to support #{stream_type}. #{e.message}")
    end

    # Helper method: Returns [true|false] if a value is blank?
    def self.blank?(value)
      if value.nil?
        true
      elsif value.is_a?(String)
        value !~ /\S/
      else
        value.respond_to?(:empty?) ? value.empty? : !value
      end
    end

    # Yields the path to a temporary file_name.
    #
    # File is deleted upon completion if present.
    def self.temp_file_name(basename, extension = "")
      result = nil
      ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir, max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        result = yield(tmpname)
      ensure
        ::File.unlink(tmpname) if ::File.exist?(tmpname)
      end
      result
    end

    class URI
      attr_reader :scheme, :hostname, :path, :user, :password, :port, :query

      def initialize(url)
        url       = url.gsub(" ", "%20")
        uri       = ::URI.parse(url)
        @scheme   = uri.scheme
        @hostname = uri.hostname
        @path     = CGI.unescape(uri.path)
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
