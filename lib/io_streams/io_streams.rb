require 'uri'

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
  include Deprecated

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
  #    # => #<IOStreams::S3::Path:0x00007fec66e3a288, @path="s3://mybucket/path/file.xls">
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
  # IOStreams.path('blah.zip').option(:encode, encoding: 'BINARY').each(:line) { |line| puts line }
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').each(:line).first
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').each(:hash).last
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').each(:hash).size
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').reader.size
  # IOStreams.path('blah.csv.zip').each(:line) { |line| puts line }
  # IOStreams.path('blah.zip').option(:pgp, passphrase: 'receiver_passphrase').read
  # IOStreams.path('blah.zip').stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').read
  # IOStreams.path('blah.zip').stream(:zip).stream(:encode, encoding: 'BINARY').read
  #
  def self.path(*elements, **args)
    return elements.first if (elements.size == 1) && args.empty? && elements.first.is_a?(IOStreams::Path)

    elements         = elements.collect(&:to_s)
    path             = ::File.join(*elements)
    extracted_scheme = path.include?("://") ? Utils::URI.new(path).scheme : nil
    klass            = scheme(extracted_scheme)
    args.empty? ? klass.new(path) : klass.new(path, **args)
  end

  # For an existing IO Stream
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').reader(&:read)
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').each(:line){ ... }
  # IOStreams.stream(io).file_name('blah.csv.zip').each(:line) { ... }
  # IOStreams.stream(io).stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').read
  def self.stream(io_stream)
    return io_stream if io_stream.is_a?(Stream)

    Stream.new(io_stream)
  end

  # For processing by either a file name or an open IO stream.
  def self.new(file_name_or_io)
    return file_name_or_io if file_name_or_io.is_a?(Stream)

    file_name_or_io.is_a?(String) ? path(file_name_or_io) : stream(file_name_or_io)
  end

  # Join the supplied path elements to a root path.
  #
  # Example:
  #    IOStreams.add_root(:default, "tmp/export")
  #
  #    IOStreams.join('file.xls')
  #    # => #<IOStreams::Paths::File:0x00007fec70391bd8 @path="tmp/export/sample">
  #
  #    IOStreams.join('file.xls').to_s
  #    # => "tmp/export/sample"
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
  #   IOStreams.temp_file
  def self.temp_file(basename, extension = "", &block)
    Utils.temp_file_name(basename, extension) { |file_name| yield(Paths::File.new(file_name).stream(:none)) }
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
  # "*"         ".profile"       false    # wildcard doesn't match leading
  # "*"         ".profile"       true     # period by default.
  # ".*"        ".profile"       true                                   {hidden: true}
  #
  # "**/*.rb"   "main.rb"        false
  # "**/*.rb"   "./main.rb"      false
  # "**/*.rb"   "lib/song.rb"    true
  # "**.rb"     "main.rb"        true
  # "**.rb"     "./main.rb"      false
  # "**.rb"     "lib/song.rb"    true
  # "*"         "dave/.profile"  true
  def self.each_child(pattern, case_sensitive: false, directories: false, hidden: false, &block)
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
  def self.add_root(root, *elements)
    raise(ArgumentError, "Invalid characters in root name #{root.inspect}") unless root.to_s =~ /\A\w+\Z/

    @root_paths[root.to_sym] = path(*elements)
  end

  def self.roots
    @root_paths.dup
  end

  # Register a file extension and the reader and writer streaming classes
  #
  # Example:
  #   # MyXls::Reader and MyXls::Writer must implement .open
  #   register_extension(:xls, MyXls::Reader, MyXls::Writer)
  def self.register_extension(extension, reader_class, writer_class)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.nil? || extension.to_s =~ /\A\w+\Z/
    @extensions[extension.nil? ? nil : extension.to_sym] = Extension.new(reader_class, writer_class)
  end

  # De-Register a file extension
  #
  # Returns [Symbol] the extension removed, or nil if the extension was not registered
  #
  # Example:
  #   register_extension(:xls)
  def self.deregister_extension(extension)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.to_s =~ /\A\w+\Z/
    @extensions.delete(extension.to_sym)
  end

  # Registered file extensions
  def self.extensions
    @extensions.dup
  end

  # Register a file extension and the reader and writer streaming classes
  #
  # Example:
  #   # MyXls::Reader and MyXls::Writer must implement .open
  #   register_scheme(:xls, MyXls::Reader, MyXls::Writer)
  def self.register_scheme(scheme, klass)
    raise(ArgumentError, "Invalid scheme #{scheme.inspect}") unless scheme.nil? || scheme.to_s =~ /\A\w+\Z/
    @schemes[scheme.nil? ? nil : scheme.to_sym] = klass
  end

  def self.schemes
    @schemes.dup
  end

  def self.scheme(scheme_name)
    @schemes[scheme_name.nil? ? nil : scheme_name.to_sym] || raise(ArgumentError, "Unknown Scheme type: #{scheme_name.inspect}")
  end

  private

  Extension = Struct.new(:reader_class, :writer_class)

  # Hold root paths
  @root_paths = {}

  # A registry to hold formats for processing files during upload or download
  @extensions = {}
  @schemes    = {}

  # Register File extensions
  register_extension(:bz2, IOStreams::Bzip2::Reader, IOStreams::Bzip2::Writer)
  register_extension(:enc, IOStreams::SymmetricEncryption::Reader, IOStreams::SymmetricEncryption::Writer)
  register_extension(:gz, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
  register_extension(:gzip, IOStreams::Gzip::Reader, IOStreams::Gzip::Writer)
  register_extension(:zip, IOStreams::Zip::Reader, IOStreams::Zip::Writer)
  register_extension(:pgp, IOStreams::Pgp::Reader, IOStreams::Pgp::Writer)
  register_extension(:gpg, IOStreams::Pgp::Reader, IOStreams::Pgp::Writer)
  register_extension(:xlsx, IOStreams::Xlsx::Reader, nil)
  register_extension(:xlsm, IOStreams::Xlsx::Reader, nil)
  register_extension(:encode, IOStreams::Encode::Reader, IOStreams::Encode::Writer)

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
