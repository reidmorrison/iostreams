require "uri"

# Streaming library for Ruby
#
# Stream types / extensions supported:
#   .zip       Zip File                                   [ :zip ]
#   .gz, .gzip GZip File                                  [ :gzip ]
#   .enc       File Encrypted using symmetric encryption  [ :enc ]
#   etc...
#   other      All other extensions will be returned as:  []
#
# When a file is encrypted, it may also be compressed:
#   .zip.enc  [ :zip, :enc ]
#   .gz.enc   [ :gz,  :enc ]
module IOStreams
  # Returns [Path] instance for the supplied complete path with optional scheme.
  #
  # Example:
  #    IOStreams.path("/usr", "local", "sample")
  #    # => #<IOStreams::Paths::File:0x00007fec66e59b60 @path="/usr/local/sample">
  #
  #    IOStreams.path("/usr", "local", "sample").to_s
  #    # => "/usr/local/sample"
  #
  #    IOStreams.path("s3://mybucket/path/file.xls")
  #    # => #<IOStreams::Paths::S3:0x00007fec66e3a288 @path="s3://mybucket/path/file.xls">
  #
  #    IOStreams.path("s3://mybucket/path/file.xls").to_s
  #    # => "s3://mybucket/path/file.xls"
  #
  #    IOStreams.path("file.xls")
  #    # => #<IOStreams::Paths::File:0x00007fec6be6aaf0 @path="file.xls">
  #
  #    IOStreams.path("files", "file.xls").to_s
  #    # => "files/file.xls"
  #
  # For Files
  # IOStreams.path('blah.zip').encoding('BINARY').each(:line) { |line| puts line }
  # IOStreams.path('blah.zip').encoding('UTF-8').each(:line) { |line| puts line }
  # IOStreams.path('blah.zip').encoding('UTF-8').each(:hash) { |hash| p hash }
  # IOStreams.path('blah.zip').encoding('UTF-8').read
  # IOStreams.path('blah.csv.zip').each(:line) { |line| puts line }
  # IOStreams.path('blah.zip').option(:pgp, passphrase: 'receiver_passphrase').read
  # IOStreams.path('blah.zip').stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').read
  # IOStreams.path('blah.zip').stream(:zip).encoding('BINARY').read
  #
  #
  # A path supplied on its own is copied, keeping its streams and options, so that changing the
  # returned path, for example with `#option`, does not change the path supplied.
  def self.path(*elements, **args)
    return elements.first.dup if (elements.size == 1) && args.empty? && elements.first.is_a?(IOStreams::Path)

    elements = elements.collect(&:to_s)
    path     = ::File.join(*elements)
    klass    = path_class(path)
    args.empty? ? klass.new(path) : klass.new(path, **args)
  end

  # Returns [Hash] the options for creating the path of the url with `IOStreams.path(url, **options)`, with the value
  # of each sensitive option, such as a password, replaced with "[FILTERED]", so that they can be displayed, for
  # example by an application that stores a url and its options to create the path later.
  #
  # The path class of the url's scheme decides which options are sensitive, see `IOStreams::Path.redact_options`.
  # Every value is replaced when the url is not valid, since then that class is not known, or when the class
  # registered for the scheme, see `IOStreams.register_scheme`, cannot say which are sensitive.
  #
  # Example:
  #   IOStreams.redact_path_options("sftp://example.org/a.csv", username: "jack", password: "secret")
  #   # => {username: "jack", password: "[FILTERED]"}
  def self.redact_path_options(url, options)
    klass = path_class(url.to_s)
    return klass.redact_options(options) if klass.respond_to?(:redact_options)

    options.to_h { |name, _value| [name, Utils::FILTERED] }
  rescue ArgumentError, ::URI::Error
    options.to_h { |name, _value| [name, Utils::FILTERED] }
  end

  # Returns [Hash<Symbol:Hash>] the options of each stream, as supplied to `IOStreams::Path#stream`, with the value of
  # each sensitive option, such as a PGP passphrase, replaced with "[FILTERED]", so that they can be displayed.
  #
  # Each stream's format decides which of its options are sensitive, see `IOStreams::StreamFormat#redact_options`.
  # Every value of a stream whose format is not registered is replaced.
  #
  # Example:
  #   IOStreams.redact_stream_options(pgp: {passphrase: "secret", recipient: "a@b.org"})
  #   # => {pgp: {passphrase: "[FILTERED]", recipient: "a@b.org"}}
  def self.redact_stream_options(streams)
    Builder.redact_streams(streams)
  end

  # Returns [Class] the path class of the scheme of the supplied path or url, such as `IOStreams::Paths::SFTP`.
  def self.path_class(path)
    scheme(path.include?("://") ? Utils::URI.new(path).scheme : nil)
  end
  private_class_method :path_class

  # For an existing IO Stream
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').read
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').each(:line){ ... }
  # IOStreams.stream(io).file_name('blah.csv.zip').each(:line) { ... }
  # IOStreams.stream(io).stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').read
  #
  # A stream supplied is copied, keeping its streams and options, so that changing the
  # returned stream does not change the stream supplied.
  def self.stream(io_stream)
    return io_stream.dup if io_stream.is_a?(Stream)

    Stream.new(io_stream)
  end

  # For processing by either a file name or an open IO stream.
  def self.new(file_name_or_io)
    return file_name_or_io.dup if file_name_or_io.is_a?(Stream)

    file_name_or_io.is_a?(String) ? path(file_name_or_io) : stream(file_name_or_io)
  end

  # Join the supplied path elements to a root path.
  #
  # Roots allow paths to reference a particular root directory, so that all path names
  # are appended to that root. Use `IOStreams.join` instead of `IOStreams.path` so that
  # the exact same code can run in production and development, yet use completely
  # different data sources in each. For example, in production the root can point to
  # an S3 bucket, while in development it points to the local file system.
  #
  # Roots are configured via an initializer at startup. Multiple roots can be setup,
  # for example one for input files, another for output files, another for reports, etc.
  # The `:default` root is used whenever a root is not supplied when calling `IOStreams.join`.
  #
  # Example:
  #    IOStreams.add_root(:default, "tmp/export")
  #    IOStreams.add_root(:ftp, "tmp/ftp")
  #
  #    IOStreams.join('file.xls')
  #    # => #<IOStreams::Paths::File:0x00007fec70391bd8 @path="tmp/export/file.xls">
  #
  #    IOStreams.join('file.xls').to_s
  #    # => "tmp/export/file.xls"
  #
  #    IOStreams.join('sample', 'file.xls', root: :ftp)
  #    # => #<IOStreams::Paths::File:0x00007fec6ee329b8 @path="tmp/ftp/sample/file.xls">
  #
  #    IOStreams.join('sample', 'file.xls', root: :ftp).to_s
  #    # => "tmp/ftp/sample/file.xls"
  #
  # Notes:
  # * Add the root path first against which this path is permitted to operate.
  #     `IOStreams.add_root(:default, "/usr/local/var/files")`
  def self.join(*elements, root: :default)
    root(root).join(*elements)
  end

  # Returns a path to a temporary file.
  # Temporary file is deleted upon block completion if present.
  #
  # Parameters:
  #   basename: [String]
  #     Base file name to include in the temp file name.
  #
  #   extension: [String]
  #     Optional extension to add to the tempfile.
  #
  # Example:
  #   IOStreams.temp_file("export", ".csv") { |path| path.write("Hello World") }
  #
  # Note: The temp file is accessible even when it is not within the allowed paths, see `IOStreams.add_allowed_path`.
  def self.temp_file(basename, extension = "")
    Utils.temp_file_name(basename, extension) do |file_name|
      # `Path#permit!` is not public, since it would let any caller access a path outside the allowed paths.
      yield(Paths::File.new(file_name).send(:permit!).stream(:none))
    end
  end

  # Returns [IOStreams::Paths::File] current or named users home path
  def self.home(username = nil)
    IOStreams::Paths::File.new(Dir.home(username))
  end

  # Returns [IOStreams::Paths::File] the current working path for this process.
  def self.working_path
    IOStreams::Paths::File.new(Dir.pwd)
  end

  # Yields Paths within the current path.
  #
  # Examples:
  #
  # # Return all children in a complete path:
  # IOStreams.each_child("/exports/files/customer/*") { |path| puts path }
  #
  # # Return all children in a complete path on S3:
  # IOStreams.each_child("s3://my_bucket/exports/files/customer/*") { |path| puts path }
  #
  # # Case Insensitive file name lookup:
  # IOStreams.each_child("/exports/files/customer/R*") { |path| puts path }
  #
  # # Case Sensitive file name lookup:
  # IOStreams.each_child("/exports/files/customer/R*", case_sensitive: true) { |path| puts path }
  #
  # # Case Insensitive recursive file name lookup:
  # IOStreams.each_child("source_files/**/fast*.rb") { |name| puts name }
  #
  # Parameters:
  #   pattern [String]
  #     The pattern is not a regexp, it is a string that may contain the following metacharacters:
  #     `*`      Matches all regular files.
  #     `c*`     Matches all regular files beginning with `c`.
  #     `*c`     Matches all regular files ending with `c`.
  #     `*c*`    Matches all regular files that have `c` in them.
  #
  #     `**`     Matches recursively into subdirectories.
  #
  #     `?`      Matches any one character.
  #
  #     `[set]`  Matches any one character in the supplied `set`.
  #     `[^set]` Does not matches any one character in the supplied `set`.
  #
  #     `\`      Escapes the next metacharacter.
  #
  #     `{a,b}`  Matches on either pattern `a` or pattern `b`.
  #
  #   case_sensitive [true|false]
  #     Whether the pattern is case-sensitive.
  #
  #   directories [true|false]
  #     Whether to yield directory names.
  #
  #   hidden [true|false]
  #     Whether to yield hidden paths.
  #
  # Examples:
  #
  # Pattern:    File name:       match?   Reason                        Options
  # =========== ================ ======   ============================= ===========================
  # "cat"       "cat"            true     # Match entire string
  # "cat"       "category"       false    # Only match partial string
  #
  # "c{at,ub}s" "cats"           true     # { } is supported
  #
  # "c?t"       "cat"            true     # "?" match only 1 character
  # "c??t"      "cat"            false    # ditto
  # "c*"        "cats"           true     # "*" match 0 or more characters
  # "c*t"       "c/a/b/t"        true     # ditto
  # "ca[a-z]"   "cat"            true     # inclusive bracket expression
  # "ca[^t]"    "cat"            false    # exclusive bracket expression ("^" or "!")
  #
  # "cat"       "CAT"            false    # case sensitive              {case_sensitive: false}
  # "cat"       "CAT"            true     # case insensitive
  #
  # "\?"        "?"              true     # escaped wildcard becomes ordinary
  # "\a"        "a"              true     # escaped ordinary remains ordinary
  # "[\?]"      "?"              true     # can escape inside bracket expression
  #
  # "*"         ".profile"       false    # wildcard doesn't match leading period by default
  # "*"         ".profile"       true     # unless hidden is enabled    {hidden: true}
  # ".*"        ".profile"       true     # leading period is explicit
  #
  # "**/*.rb"   "main.rb"        false
  # "**/*.rb"   "./main.rb"      false
  # "**/*.rb"   "lib/song.rb"    true
  # "**.rb"     "main.rb"        true
  # "**.rb"     "./main.rb"      false
  # "**.rb"     "lib/song.rb"    true
  # "*"         "dave/.profile"  true
  def self.each_child(pattern, case_sensitive: false, directories: false, hidden: false, &)
    # The directory before the first element with pattern characters is the path, such as `s3://bucket/data`
    # for `s3://bucket/data/*.csv`, which lists the pattern within it.
    matcher = Paths::Matcher.new(pattern, case_sensitive: case_sensitive, hidden: hidden)
    path(matcher.directory).
      each_child(matcher.pattern, case_sensitive: case_sensitive, directories: directories, hidden: hidden, &)
  end

  # Returns [IOStreams::Path] a copy of the default root path, or the named root path,
  # so that changing it does not change the root.
  def self.root(root = :default)
    path = @root_paths[root.to_sym] || raise(ArgumentError, "Root: #{root.inspect} has not been registered.")
    path.dup
  end

  # Add a named root path
  #
  # Returns [IOStreams::Path] the root path, which is frozen so that it cannot be changed for the whole process.
  # `IOStreams.root` and `IOStreams.join` return copies of it that can be changed.
  def self.add_root(root, *elements, **args)
    raise(ArgumentError, "Invalid characters in root name #{root.inspect}") unless root.to_s =~ /\A\w+\Z/

    @root_paths[root.to_sym] = path(*elements, **args).freeze
  end

  # Returns [Hash<Symbol, IOStreams::Path>] a copy of each root path, by name.
  def self.roots
    @root_paths.transform_values(&:dup)
  end

  # Restrict IOStreams to only access paths within the supplied path.
  #
  # Once any allowed path has been added, reading, writing, listing, deleting or otherwise accessing
  # a path that is not within one of the allowed paths raises `IOStreams::Errors::AccessDenied`.
  # This prevents an untrusted file name, for example one supplied by a user, from accessing anything
  # else that the process can access.
  #
  # Parameters: Same as `IOStreams.path`
  #
  # Returns [String] the normalized path that was added, against which paths are compared.
  #
  # Example:
  #    IOStreams.add_allowed_path("/var/data/uploads")
  #    IOStreams.add_allowed_path("s3://my-bucket/exports")
  #
  #    IOStreams.path("/var/data/uploads/file.csv").read
  #    IOStreams.path("/etc/passwd").read
  #    # => IOStreams::Errors::AccessDenied
  #
  # Notes:
  # * By default no allowed paths are added, and every path is accessible.
  # * Add allowed paths in an initializer at startup, where they cannot be changed by untrusted input.
  # * Paths are normalized before they are compared, so `..` cannot be used to leave an allowed path:
  #   * Local file names are resolved to their real path, following symbolic links.
  #     A relative path is resolved against the current working directory when it is added.
  #   * For S3 the bucket must match, and keys containing `.` or `..` segments are denied.
  #   * For SFTP and HTTP the host and port must match, and `.` and `..` segments are resolved.
  # * `#each_child` skips children that are not within the allowed paths, for example a symbolic link
  #   to a file elsewhere.
  # * Temp files created by `IOStreams.temp_file` are always accessible.
  # * Paths from a scheme registered with `IOStreams.register_scheme` are denied, unless its path class
  #   implements the private method `#allowed_location`.
  # * A local file could be replaced with a symbolic link after it is checked but before it is opened.
  #   Allowed paths do not prevent this, so do not allow paths where untrusted users can create files.
  def self.add_allowed_path(*elements, **args)
    location = allowed_location(path(*elements, **args))
    @allowed_paths_mutex.synchronize { @allowed_paths = (@allowed_paths + [location]).uniq.freeze }
    location
  end

  # Removes a path previously added with `IOStreams.add_allowed_path`.
  #
  # Returns [String] the normalized path that was removed.
  def self.delete_allowed_path(*elements, **args)
    location = allowed_location(path(*elements, **args))
    @allowed_paths_mutex.synchronize { @allowed_paths = (@allowed_paths - [location]).freeze }
    location
  end

  # Returns [Array<String>] the normalized allowed paths, see `IOStreams.add_allowed_path`.
  def self.allowed_paths
    @allowed_paths
  end

  # Returns [true|false] whether the supplied path can be accessed, see `IOStreams.add_allowed_path`.
  #
  # Always true when no allowed paths have been added.
  #
  # Parameters: Same as `IOStreams.path`
  def self.allowed_path?(*elements, **args)
    path(*elements, **args).allowed?
  end

  def self.allowed_location(path)
    # `Path#allowed_location` is not public, so that how each path is normalized is not part of the public API.
    path.send(:allowed_location)
  rescue Errors::AccessDenied => e
    raise(ArgumentError, e.message)
  end

  private_class_method :allowed_location

  # Set the temporary path to use when creating local temp files.
  def self.temp_dir=(temp_dir)
    temp_dir = File.expand_path(temp_dir)
    FileUtils.mkdir_p(temp_dir)

    @temp_dir = temp_dir
  end

  # Returns the temporary path used when creating local temp files.
  #
  # Default:
  #   ENV['TMPDIR'], or ENV['TMP'], or ENV['TEMP'], or `Etc.systmpdir`, or '/tmp', otherwise '.'
  def self.temp_dir
    @temp_dir ||= Dir.tmpdir
  end

  @temp_dir = nil

  # Apply `allowed_columns`, `required_columns` and `skip_unknown` to every input when reading records.
  #
  # When true, they apply to a header row read from the file, to the supplied `columns:`, to a header row
  # read with `cleanse_header: false`, and to the keys of each JSON or `:hash` record. JSON keys are cleansed
  # like a header row, unless `cleanse_header` is false, unknown keys are skipped or raise
  # `IOStreams::Errors::InvalidHeader`, and a record missing a required column raises
  # `IOStreams::Errors::InvalidHeader`.
  #
  # When false, as before v3.0, they only apply to a header row read from the file, and only when
  # `cleanse_header` is true. They are ignored for JSON and `:hash` input, when `columns:` is supplied, and
  # with `cleanse_header: false`, and a warning is logged when applying them would change the result.
  # Since the format is usually inferred from the file name, renaming an uploaded file to `.json`
  # then bypasses them.
  #
  # Default: true. It defaulted to false before v3.0.
  #
  # Example:
  #   IOStreams.enforce_column_restrictions = false
  def self.enforce_column_restrictions=(enforce)
    raise(ArgumentError, "enforce_column_restrictions must be true or false") unless [true, false].include?(enforce)

    @enforce_column_restrictions = enforce
  end

  # Returns [true|false] whether column restrictions apply to every input, see `IOStreams.enforce_column_restrictions=`.
  def self.enforce_column_restrictions?
    @enforce_column_restrictions
  end

  @enforce_column_restrictions = true

  # Returns [Logger] the logger used by IOStreams for debug logging.
  #
  # When SemanticLogger is loaded a SemanticLogger instance is used by default,
  # otherwise no logging is performed unless a logger is assigned via #logger=.
  def self.logger
    @logger
  end

  # Replace the logger used by IOStreams.
  #
  # Set to nil to disable logging.
  def self.logger=(logger)
    @logger = logger
  end

  @logger = (SemanticLogger[IOStreams] if defined?(SemanticLogger::Logger))

  # Register a file extension and the format that reads and writes it.
  #
  # The format, usually a module such as `IOStreams::Gzip`, extends `IOStreams::StreamFormat`, which checks the
  # options of its reader and writer and opens them, and answers:
  #   reader_class: [Class|nil] the class that reads the format, or nil when it cannot be read.
  #   writer_class: [Class|nil] the class that writes the format, or nil when it cannot be written.
  #   compressed?:  [true|false] whether data in the format is compressed.
  #   encrypted?:   [true|false] whether data in the format is encrypted.
  #
  # Or supply just the reader and writer classes, for a format that is neither compressed nor encrypted.
  #
  # The reader and writer classes must implement `.open`, see `IOStreams::Reader` and `IOStreams::Writer`.
  #
  # Raises ArgumentError for a reserved keyword, such as `:encode` or `:none`.
  #
  # Example:
  #   register_extension(:xz, MyXz)
  #
  #   register_extension(:xls, MyXls::Reader, MyXls::Writer)
  def self.register_extension(extension, *format_or_classes)
    format =
      case format_or_classes.size
      when 1
        format_or_classes.first
      when 2
        Extension.new(*format_or_classes).freeze
      else
        raise(ArgumentError, "wrong number of arguments (given #{format_or_classes.size + 1}, expected 2..3)")
      end
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.nil? || extension.to_s =~ /\A\w+\Z/
    if Builder.reserved_keyword?(extension&.to_sym)
      raise(ArgumentError, "Cannot register the extension #{extension.inspect}, which is a reserved keyword")
    end

    missing = FORMAT_METHODS.reject { |name| format.respond_to?(name) }
    unless missing.empty?
      raise(ArgumentError,
            "Invalid format for extension #{extension.inspect}: #{format.inspect} does not respond to " \
            "#{missing.join(', ')}. See IOStreams.register_extension.")
    end

    @extensions[extension&.to_sym] = format
  end

  # De-Register a file extension
  #
  # Returns [Symbol] the extension removed, or nil if the extension was not registered
  #
  # Example:
  #   deregister_extension(:xls)
  def self.deregister_extension(extension)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.to_s =~ /\A\w+\Z/

    @extensions.delete(extension.to_sym)
  end

  # Returns [Hash<Symbol, Object>] the format registered for each file extension, see `register_extension`.
  # A format registered by its reader and writer classes is a frozen `IOStreams::Extension`.
  def self.extensions
    @extensions.dup
  end

  # Register a URI scheme and the path class that handles it
  #
  # Example:
  #   register_scheme(:gcs, MyGoogleCloudStoragePath)
  def self.register_scheme(scheme, klass)
    raise(ArgumentError, "Invalid scheme #{scheme.inspect}") unless scheme.nil? || scheme.to_s =~ /\A\w+\Z/

    @schemes[scheme&.to_sym] = klass
  end

  def self.schemes
    @schemes.dup
  end

  def self.scheme(scheme_name)
    @schemes[scheme_name&.to_sym] || raise(ArgumentError, "Unknown Scheme type: #{scheme_name.inspect}")
  end

  # The methods that a format registered with `register_extension` must respond to.
  FORMAT_METHODS = %i[
    reader_class writer_class compressed? encrypted?
    option_names valid_option_names validate_options open_stream redact_options
  ].freeze
  private_constant :FORMAT_METHODS

  # A format registered with `register_extension` by its reader and writer classes,
  # whose data is neither compressed nor encrypted.
  Extension = Struct.new(:reader_class, :writer_class) do
    include StreamFormat

    def compressed?
      false
    end

    def encrypted?
      false
    end
  end

  # Hold root paths
  @root_paths = {}

  # Hold allowed paths. Replaced rather than modified, so that it can be read without a lock.
  @allowed_paths       = [].freeze
  @allowed_paths_mutex = Mutex.new

  # A registry to hold formats for processing files during upload or download
  @extensions = {}
  @schemes    = {}

  # Register File extensions
  register_extension(:bz2, IOStreams::Bzip2)
  register_extension(:enc, IOStreams::SymmetricEncryption)
  register_extension(:gz, IOStreams::Gzip)
  register_extension(:gzip, IOStreams::Gzip)
  register_extension(:zip, IOStreams::Zip)
  register_extension(:pgp, IOStreams::Pgp)
  register_extension(:gpg, IOStreams::Pgp)
  register_extension(:xlsx, IOStreams::Xlsx)
  register_extension(:xlsm, IOStreams::Xlsx)

  # Register Schemes
  #
  # Examples:
  #    path/file_name
  #    http://hostname/path/file_name
  #    https://hostname/path/file_name
  #    sftp://hostname/path/file_name
  #    s3://bucket/key
  register_scheme(nil, IOStreams::Paths::File)
  register_scheme(:file, IOStreams::Paths::File)
  register_scheme(:http, IOStreams::Paths::HTTP)
  register_scheme(:https, IOStreams::Paths::HTTP)
  register_scheme(:sftp, IOStreams::Paths::SFTP)
  register_scheme(:s3, IOStreams::Paths::S3)
end
