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
  # IOStreams.path('blah.zip').option(:encode, encoding: 'BINARY').each_line { |line puts line }
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').each_line.first
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').each_record.last
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').each_record.size
  # IOStreams.path('blah.zip').option(:encode, encoding: 'UTF-8').reader.size
  # IOStreams.path('blah.csv.zip').each_line { |line puts line }
  # IOStreams.path('blah.zip').option(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
  # IOStreams.path('blah.zip').stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
  # IOStreams.path('blah.zip').stream(:zip).stream(:encode, encoding: 'BINARY').reader(&:read)
  #
  def self.path(*elements)
    path = ::File.join(*elements)
    uri  = URI.parse(path)
    scheme(uri.scheme).new(path)
  end

  # For an existing IO Stream
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').reader(&:read)
  # IOStreams.stream(io).file_name('blah.zip').encoding('BINARY').each_line(...)
  # IOStreams.stream(io).file_name('blah.csv.zip').each_line(...)
  # IOStreams.stream(io).stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
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

  # Returns a path to a local temporary file.
  def self.temp_file(*args)
    # TODO: Possible enhancement: Add a :temp root so that temp files can be stored anywhere, or the location changed.
    Paths::File.temp_file(*args)
  end

  # Returns [IOStreams::Paths::File] current or named users home path
  def self.home(username = nil)
    IOStreams::Paths::File.new(Dir.home(username))
  end

  # Returns [IOStreams::Paths::File] the current working path for this process.
  def self.working_path
    IOStreams::Paths::File.new(Dir.pwd)
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
