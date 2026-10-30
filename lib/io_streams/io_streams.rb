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
  # A name that IOStreams v3.0 reads as another file or url, such as a local name starting with `~/`, or an SFTP or
  # HTTP url without a path, is deprecated, and reports a deprecation warning, see `IOStreams::Path.name_deprecation`.
  def self.path(*elements, **args)
    build_path(elements, args, :name_deprecation)
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
  # The extension registered for each stream decides which of its options are sensitive, see
  # `IOStreams::Extension#redact_options`, as it does for `#inspect`. Every value of a stream that is not registered is
  # replaced, as are options that are not a Hash.
  #
  # Example:
  #   IOStreams.redact_stream_options(pgp: {passphrase: "secret", recipient: "a@b.org"})
  #   # => {pgp: {passphrase: "[FILTERED]", recipient: "a@b.org"}}
  def self.redact_stream_options(streams)
    Utils.redact_streams(streams) { |name| @extensions[name.to_s.to_sym] }
  end

  # Returns [Class] the path class of the scheme of the supplied path or url, such as `IOStreams::Paths::SFTP`.
  def self.path_class(path)
    scheme(path.include?("://") ? Utils::URI.new(path).scheme : nil)
  end
  private_class_method :path_class

  # Returns [IOStreams::Path] the path of the supplied elements, joined into one name or url, created with the supplied
  # arguments, see .path, reporting the deprecation warning, if any, that the class method of its path class with the
  # supplied name gives for the name, see `IOStreams::Path.name_deprecation`, as the application supplied it.
  def self.build_path(elements, args, deprecation)
    return elements.first if (elements.size == 1) && args.empty? && elements.first.is_a?(IOStreams::Path)

    name  = Utils::PathName.join(*elements.collect(&:to_s))
    klass = path_class(name)
    path  = args.empty? ? klass.new(name) : klass.new(name, **args)
    warn_deprecated_name(klass, deprecation, name)
    path
  end
  private_class_method :build_path

  # Returns [IOStreams::Path] the path of the supplied name or url, as .path does, without reporting a deprecation
  # warning for the name, for IOStreams itself, which derives it from the name that the application supplied, such as
  # the directory that a pattern is matched within, see `IOStreams::Paths::Matcher`.
  def self.path_of(name)
    path_class(name).new(name)
  end
  private_class_method :path_of

  # Reports the deprecation warning that the supplied class method of the path class gives for a name or url that the
  # application supplied, if any: `:name_deprecation` when IOStreams v3.0 reads it as another file or url, or
  # `:location_deprecation` when it reads it as another location, which the allowed paths compare, see
  # `IOStreams::Path.name_deprecation`.
  def self.warn_deprecated_name(klass, deprecation, name)
    message = klass.public_send(deprecation, name) if klass.respond_to?(deprecation)
    Deprecation.warn(message) if message
  end
  private_class_method :warn_deprecated_name

  # Reports a deprecation warning for the name of the directory of a pattern, see .warn_deprecated_name. A pattern that
  # is not a valid url, such as one with braces, is matched within the directory before its first pattern character,
  # which the warnings do not apply to, see `IOStreams::Paths::Matcher`.
  def self.warn_deprecated_pattern(pattern)
    klass = path_class(pattern)
  rescue ArgumentError, ::URI::Error
    nil
  else
    warn_deprecated_name(klass, :name_deprecation, pattern)
  end
  private_class_method :warn_deprecated_pattern

  # Returns [true|false] whether the object is a `Pathname`, which IOStreams v3.0 reads as the name of a file.
  def self.pathname?(object)
    return false unless defined?(::Pathname)

    object.is_a?(::Pathname)
  end
  private_class_method :pathname?

  # For an existing IO Stream
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').read
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').each(:line){ ... }
  # IOStreams.stream(io).file_name('blah.csv.zip').each(:line) { ... }
  # IOStreams.stream(io).stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').read
  #
  # A `Pathname` is deprecated, since IOStreams v3.0 raises ArgumentError for it, as for a String: it reports a
  # deprecation warning, see `IOStreams::Deprecation`.
  def self.stream(io_stream)
    return io_stream if io_stream.is_a?(Stream)

    if pathname?(io_stream)
      Deprecation.warn("a Pathname supplied to IOStreams.stream is deprecated, since v3.0 raises ArgumentError for it, " \
                       "as for a String: supply IOStreams.path(pathname) instead, and call #raw on it to read or " \
                       "write the data as it is stored")
    end
    Stream.new(io_stream)
  end

  # For processing by either a file name or an open IO stream.
  #
  # A `Pathname` is deprecated, which it reads and writes as an IO, since IOStreams v3.0 returns the path of the file
  # that it names, which applies the streams of its file name: it reports a deprecation warning, see
  # `IOStreams::Deprecation`. So is one supplied to `#copy_from`, `#copy_to` or `#move_to`, which call it.
  def self.new(file_name_or_io)
    return file_name_or_io if file_name_or_io.is_a?(Stream)
    return path(file_name_or_io) if file_name_or_io.is_a?(String)
    return stream(file_name_or_io) unless pathname?(file_name_or_io)

    Deprecation.warn("a Pathname supplied to IOStreams.new, #copy_from, #copy_to or #move_to is deprecated, since " \
                     "v3.0 takes it as the name of a file, applying the streams that its file name implies, rather " \
                     "than as an IO: supply pathname.to_s instead, and call #raw on its path to read or write the " \
                     "data as it is stored")
    Stream.new(file_name_or_io)
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
  #
  # The path reads and writes its data as it is stored, whatever its extension, while IOStreams v3.0 applies the streams
  # that its extension implies, such as `.gz`, so reading or writing it without #raw, which reads and writes the data
  # as it is stored on both, is deprecated when its extension implies streams, and reports a deprecation warning, see
  # `IOStreams::Deprecation`.
  def self.temp_file(basename, extension = "")
    Utils.temp_file_name(basename, extension) do |file_name|
      yield(Paths::File.new(file_name).send(:permit!).send(:no_streams, temp_file: true))
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
  def self.each_child(pattern, case_sensitive: false, directories: false, hidden: false, &block)
    warn_deprecated_pattern(pattern)
    matcher = Paths::Matcher.new(nil, pattern, case_sensitive: case_sensitive, hidden: hidden)

    # When the pattern includes an exact file name without any pattern characters
    if matcher.pattern.nil?
      block.call(matcher.path) if matcher.path.exist?
      return
    end
    matcher.path.each_child(matcher.pattern, case_sensitive: case_sensitive, directories: directories, hidden: hidden, &block)
  end

  # Returns [IOStreams::Paths::File] the default root path, or the named root path
  def self.root(root = :default)
    @root_paths[root.to_sym] || raise(ArgumentError, "Root: #{root.inspect} has not been registered.")
  end

  # Add a named root path
  #
  # Returns [IOStreams::Path] the root path, which the whole process shares, see `IOStreams.join`. Changing it in place,
  # such as with `#stream` or `#option`, whether through this path, a path supplied as the root, `IOStreams.root`,
  # `IOStreams.roots`, or `IOStreams.join` without elements, is deprecated, and reports a deprecation warning, since v3.0
  # keeps its own frozen copy of the root, which this method returns, and the others return copies of it, so that
  # changing them no longer changes the root: change a copy of it instead, such as `IOStreams.root(:uploads).dup`, or a
  # path joined to it, such as `IOStreams.join("a.csv", root: :uploads)`.
  def self.add_root(root, *elements, **args)
    raise(ArgumentError, "Invalid characters in root name #{root.inspect}") unless root.to_s =~ /\A\w+\Z/

    path = path(*elements, **args)
    # The path class of a scheme registered with `IOStreams.register_scheme` need not be an `IOStreams::Path`.
    path.send(:root!, root.to_sym) if path.is_a?(Path)
    @root_paths[root.to_sym] = path
  end

  def self.roots
    @root_paths.dup
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
    location = allowed_location(build_path(elements, args, :location_deprecation))
    @allowed_paths_mutex.synchronize { @allowed_paths = (@allowed_paths + [location]).uniq.freeze }
    location
  end

  # Removes a path previously added with `IOStreams.add_allowed_path`.
  #
  # Returns [String] the normalized path that was removed.
  def self.delete_allowed_path(*elements, **args)
    location = allowed_location(build_path(elements, args, :location_deprecation))
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
    build_path(elements, args, :location_deprecation).send(:allowed?)
  end

  def self.allowed_location(path)
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
  # When false, they only apply to a header row read from the file, and only when `cleanse_header` is true.
  # They are ignored for JSON and `:hash` input, when `columns:` is supplied, and with `cleanse_header: false`,
  # and a warning is logged when applying them would change the result.
  #
  # When true, they also apply to the supplied `columns:`, to a header row read with `cleanse_header: false`,
  # and to the keys of each JSON or `:hash` record. JSON keys are cleansed like a header row, unless
  # `cleanse_header` is false, unknown keys are skipped or raise `IOStreams::Errors::InvalidHeader`,
  # and a record missing a required column raises `IOStreams::Errors::InvalidHeader`.
  #
  # Since the format is usually inferred from the file name, set this to true when the allowed columns
  # restrict what an uploaded file can set, so that renaming the file to `.json` cannot bypass them.
  #
  # Default: false.
  #
  # Example:
  #   IOStreams.enforce_column_restrictions = true
  #
  # Deprecated: it only applies to the column options, which are deprecated, see `IOStreams::Stream#each`, and which
  # v3.0 removes, with this setting. Describe the columns of the file with `IOStreams::Stream#schema` instead, whose
  # `fieldsMatch` and `constraints` apply to every input. It still applies to the column options, and reports a
  # deprecation warning, see `IOStreams::Deprecation`, so keep it until they are replaced with a schema. The setting
  # is held by `IOStreams::Tabular::HeaderMapping`, which applies it, and reads it without a deprecation warning.
  def self.enforce_column_restrictions=(enforce)
    raise(ArgumentError, "enforce_column_restrictions must be true or false") unless [true, false].include?(enforce)

    Deprecation.warn("IOStreams.enforce_column_restrictions= #{ENFORCE_COLUMN_RESTRICTIONS_DEPRECATION}")
    Tabular::HeaderMapping.enforce_column_restrictions = enforce
  end

  # Returns [true|false] whether column restrictions apply to every input, see `IOStreams.enforce_column_restrictions=`.
  #
  # Deprecated, as `IOStreams.enforce_column_restrictions=` is. It reports a deprecation warning, see
  # `IOStreams::Deprecation`.
  def self.enforce_column_restrictions?
    Deprecation.warn("IOStreams.enforce_column_restrictions? #{ENFORCE_COLUMN_RESTRICTIONS_DEPRECATION}")
    Tabular::HeaderMapping.enforce_column_restrictions?
  end

  # Why `IOStreams.enforce_column_restrictions=` and `IOStreams.enforce_column_restrictions?` are deprecated, and what
  # to use instead.
  ENFORCE_COLUMN_RESTRICTIONS_DEPRECATION =
    "is deprecated, since it only applies to the column options, such as allowed_columns:, which are deprecated: " \
    "describe the columns of the file with #schema instead, whose fieldsMatch and constraints apply to every input, " \
    "and then remove it".freeze
  private_constant :ENFORCE_COLUMN_RESTRICTIONS_DEPRECATION

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

  # Register a file extension and the reader and writer streaming classes
  #
  # Returns [IOStreams::Extension] the extension registered, whose setters, such as `writer_class=`, are deprecated,
  # see `IOStreams::Extension::Deprecations`.
  #
  # Registering `:encode` or `:none`, in any case, is deprecated, see RESERVED_EXTENSIONS, as is a name that IOStreams
  # 3.0 does not register as it is, see .extension_name_deprecation: one that ends with a line break, or that is not in
  # lower case. It still registers the extension, and reports a deprecation warning, see `IOStreams::Deprecation`.
  #
  # Example:
  #   # MyXls::Reader and MyXls::Writer must implement .open
  #   register_extension(:xls, MyXls::Reader, MyXls::Writer)
  def self.register_extension(extension, reader_class, writer_class)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.nil? || extension.to_s =~ /\A\w+\Z/

    if (reason = extension_name_deprecation(extension, RESERVED_EXTENSIONS))
      Deprecation.warn("IOStreams.register_extension(#{extension.inspect}, ...) is deprecated, since #{reason}")
    end
    @extensions[extension&.to_sym] = Extension.registered(reader_class, writer_class)
  end

  # The names that IOStreams 3.0 reserves, so that registering an extension of one of them, in any case, which it raises
  # ArgumentError for, is deprecated, see .register_extension, with why, and what to do instead.
  RESERVED_EXTENSIONS = {
    encode: "the encode stream is built in, which IOStreams 3.0 does not let an extension replace: register the " \
            "reader and writer under another name instead, and apply them with #stream, or set the encoding of the " \
            "text with #encoding",
    none:   "IOStreams 3.0 reserves :none, which stream(:none) took to apply no streams, register the stream under " \
            "another name instead"
  }.freeze
  private_constant :RESERVED_EXTENSIONS

  # Registers an extension that IOStreams builds in, as .register_extension does, whose methods of a Struct, other than
  # `reader_class` and `writer_class`, are deprecated too, see `IOStreams::Extension::Deprecations`.
  def self.register_built_in_extension(extension, reader_class, writer_class)
    @extensions[extension] = Extension.registered(reader_class, writer_class, built_in: true)
  end
  private_class_method :register_built_in_extension

  # De-Register a file extension
  #
  # Returns [IOStreams::Extension] the extension removed, or nil if the extension was not registered
  #
  # Deregistering `:encode`, in any case, is deprecated, since the encode stream is built in, which IOStreams 3.0 does
  # not deregister, see BUILT_IN_STREAMS. It still removes it, so that `#encoding` then raises ArgumentError. So is a
  # name that IOStreams 3.0 does not deregister as it is, see .extension_name_deprecation: one that ends with a line
  # break, or that is not in lower case. Each reports a deprecation warning, see `IOStreams::Deprecation`.
  #
  # Example:
  #   deregister_extension(:xls)
  def self.deregister_extension(extension)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.to_s =~ /\A\w+\Z/

    if (reason = extension_name_deprecation(extension, BUILT_IN_STREAMS))
      Deprecation.warn("IOStreams.deregister_extension(#{extension.inspect}) is deprecated, since #{reason}")
    end
    @extensions.delete(extension.to_sym)
  end

  # The streams that IOStreams 3.0 builds in, rather than registers, so that deregistering one of them, in any case,
  # which it does not deregister, is deprecated, see .deregister_extension, with why, and what to do instead.
  BUILT_IN_STREAMS = {
    encode: "the encode stream is built in, which IOStreams 3.0 does not deregister, so remove it: IOStreams 3.0 " \
            "applies the encode stream only where #encoding sets it"
  }.freeze
  private_constant :BUILT_IN_STREAMS

  # Returns [String|nil] why the name of an extension, as the application supplied it to .register_extension or
  # .deregister_extension, is deprecated, or nil when IOStreams 3.0 takes it as it is:
  # - A name that ends with a line break, such as `"xz\n"`, which the check of the name accepts, while IOStreams 3.0
  #   raises ArgumentError for it.
  # - A name of the supplied reasons, in any case, such as RESERVED_EXTENSIONS, with the reason that it gives.
  # - A name that is not in lower case, such as `:XZ`, since IOStreams 3.0 registers and deregisters it in lower case,
  #   as `:xz`, which matches the file names that end in `.xz` in any case, as their extensions are compared.
  def self.extension_name_deprecation(extension, reasons)
    name  = extension.to_s
    lower = name.downcase
    if name.end_with?("\n")
      "IOStreams 3.0 raises ArgumentError for a name that ends with a line break, remove the line break"
    elsif reasons.key?(lower.to_sym)
      reasons[lower.to_sym]
    elsif name != lower
      "IOStreams 3.0 takes the name of an extension in lower case, as #{lower.to_sym.inspect}, which matches the file " \
        "names that end in .#{lower}, in any case, use #{lower.to_sym.inspect} instead"
    end
  end
  private_class_method :extension_name_deprecation

  # Returns [Hash<Symbol, IOStreams::Extension>] the extension registered for each file extension, see
  # .register_extension.
  #
  # Each extension answers `reader_class` and `writer_class`, as the format that IOStreams 3.0 returns for each of
  # its built-in extensions does, such as `IOStreams::Gzip` for `:gz`. Its other methods of a Struct, such as `to_a`,
  # `to_h` or `[]`, are deprecated for a built-in extension, and its setters, such as `writer_class=`, for every
  # extension, see `IOStreams::Extension::Deprecations`.
  def self.extensions
    @extensions.dup
  end

  # Returns [Array<Symbol>] the names of the formats of the rows and records of a file that `IOStreams::Stream#format`
  # accepts, such as `:csv`, `:json` or `:fixed`, frozen. The list grows as formats are added, so check whether a name
  # is included, rather than rely on its order or its length.
  def self.tabular_formats
    Tabular.registered_formats.freeze
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

  # The reader and writer classes registered for a file extension, see `IOStreams.register_extension`.
  Extension = Struct.new(:reader_class, :writer_class) do
    # Returns [Array<Symbol>] the options whose values must not be displayed, such as a passphrase, as declared
    # by the reader and the writer with `sensitive_option_names`.
    def sensitive_option_names
      [reader_class, writer_class].flat_map do |klass|
        (klass.sensitive_option_names if klass.respond_to?(:sensitive_option_names)) || []
      end.uniq
    end

    # Returns [Hash] the options with the value of each sensitive option replaced with "[FILTERED]", so that
    # they can be displayed, for example by `#inspect`.
    #
    # Sensitive options are those that the reader or the writer declares, see #sensitive_option_names, and,
    # as a precaution, any option whose name suggests a secret, such as one that contains `password` or `token`, see
    # `IOStreams::Utils.redact_options`, which owns that list.
    def redact_options(options)
      Utils.redact_options(options, sensitive_option_names)
    end
  end

  class Extension
    # Returns [IOStreams::Extension] a new extension of the supplied reader and writer classes, as
    # `IOStreams.register_extension` registers it, whose setters are deprecated, or as IOStreams registers one that it
    # builds in (built_in: true), whose other methods of a Struct are deprecated too, see Deprecations.
    def self.registered(reader_class, writer_class, built_in: false)
      new(reader_class, writer_class).tap { |extension| extension.send(:registered!, built_in) }
    end

    # Reports a deprecation warning, see `IOStreams::Deprecation`, for the methods of a Struct of a registered extension
    # that IOStreams 3.0 does not answer, see .registered, and then does as before. It is prepended to the class, rather
    # than extended onto each extension, so that an extension keeps its class, which JRuby's `Struct#eql?` compares.
    #
    # - The setters of a registered extension, such as `writer_class=`, and `[]=`, change the extension registered for
    #   the whole process, since `IOStreams.extensions` returns a copy of the registry that shares its extensions, which
    #   IOStreams 3.0 freezes. They still report one once it is no longer registered, such as one that
    #   `IOStreams.deregister_extension` returned, see #setter_deprecation, since IOStreams 3.0 raises for them there too.
    # - For an extension that IOStreams builds in, such as `:gz`, IOStreams 3.0 returns the format that it registers,
    #   such as `IOStreams::Gzip`, rather than a Struct, see `IOStreams.extensions`. The format answers `reader_class`
    #   and `writer_class`, but none of the other methods of a Struct, such as #to_a, nor those of `Enumerable`, which
    #   call #each.
    #
    # An extension that is not registered, such as one that an application creates, reports nothing.
    module Deprecations
      # The methods that change an extension.
      SETTERS = %i[reader_class= writer_class= []=].freeze

      # The methods of a Struct that read an extension, other than `reader_class` and `writer_class`, and other than
      # those that every object answers, such as `==` and `inspect`.
      STRUCT_METHODS = %i[[] to_a values deconstruct to_h each each_pair members size length values_at select filter dig
                          deconstruct_keys].freeze

      SETTERS.each do |name|
        define_method(name) do |*args|
          Deprecation.warn("##{name} #{setter_deprecation}") if @registered
          super(*args)
        end
      end

      STRUCT_METHODS.each do |name|
        define_method(name) do |*args, &block|
          if @built_in
            Deprecation.warn("##{name} on a built-in extension of IOStreams.extensions is deprecated, since IOStreams " \
                             "3.0 returns its format, such as IOStreams::Gzip for :gz, rather than a Struct, use " \
                             "#reader_class and #writer_class instead")
          end
          super(*args, &block)
        end
      end

      # Prints the extension for `pp` as it prints any other Struct, but reads each member with its reader, such as
      # `reader_class`, rather than with #[], as `pp` does.
      def pretty_print(printer)
        printer.group(1, "#<struct #{self.class.name}", ">") do
          printer.seplist(self.class.members, -> { printer.text(",") }) do |member|
            printer.breakable
            printer.text("#{member}=")
            printer.group(1) do
              printer.breakable("")
              printer.pp(public_send(member))
            end
          end
        end
      end

      private

      # Marks this extension as registered, see .registered, by IOStreams itself when built_in.
      def registered!(built_in)
        @registered = true
        @built_in   = built_in
      end

      # Returns [String] why a setter of this extension, which was registered, see .registered, is deprecated, after the
      # name of the setter: while it is registered, that the setter changes the extension registered for the whole
      # process, and once it is not, such as after `IOStreams.deregister_extension` removed it, or another extension was
      # registered in its place, that IOStreams 3.0 does not allow it either, since it freezes the extension that it
      # registers, and returns the format of one that it builds in, such as `IOStreams::Gzip`, which has no setters.
      def setter_deprecation
        if IOStreams.extensions.each_value.any? { |extension| extension.equal?(self) }
          "on an extension of IOStreams.extensions is deprecated, since it changes the registered extension for the " \
            "whole process, which IOStreams 3.0 does not allow, use IOStreams.register_extension to change it instead"
        else
          "on an extension that is no longer registered, such as one that IOStreams.deregister_extension returned, is " \
            "deprecated, since IOStreams 3.0 does not allow it on an extension that it registered, supply the classes " \
            "to IOStreams.register_extension instead"
        end
      end
    end
    prepend Deprecations
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
  register_built_in_extension(:bz2, IOStreams::Bzip2::Reader, IOStreams::Bzip2::Writer)
  register_built_in_extension(:enc, IOStreams::SymmetricEncryption::Reader, IOStreams::SymmetricEncryption::Writer)
  register_built_in_extension(:gz, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
  register_built_in_extension(:gzip, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
  register_built_in_extension(:zip, IOStreams::Zip::Reader, IOStreams::Zip::Writer)
  register_built_in_extension(:pgp, IOStreams::Pgp::Reader, IOStreams::Pgp::Writer)
  register_built_in_extension(:gpg, IOStreams::Pgp::Reader, IOStreams::Pgp::Writer)
  register_built_in_extension(:xlsx, IOStreams::Xlsx::Reader, nil)
  register_built_in_extension(:xlsm, IOStreams::Xlsx::Reader, nil)
  register_built_in_extension(:encode, IOStreams::Encode::Reader, IOStreams::Encode::Writer)

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

  # Reports a deprecation warning when the supplied version of Ruby is older than 3.3, which IOStreams 3.0 requires.
  #
  # Called once, as IOStreams is loaded, so that the warning names the line of the application that loaded it, such as
  # its `Bundler.require`, see `IOStreams::Deprecation.warn_on_load`. It is only reported while deprecation warnings
  # are on as IOStreams is loaded, such as with `RUBYOPT=-W:deprecated`, and RubyGems, which compares the versions, is
  # loaded, which it is unless Ruby runs with `--disable-gems`.
  def self.warn_unsupported_ruby(version = RUBY_VERSION)
    return unless defined?(::Gem::Version) && ::Gem::Version.new(version) < ::Gem::Version.new("3.3")

    Deprecation.warn_on_load("Ruby #{version} is deprecated, since IOStreams 3.0 requires Ruby 3.3 or later, so " \
                             "upgrade Ruby")
  end
  private_class_method :warn_unsupported_ruby

  warn_unsupported_ruby
end
