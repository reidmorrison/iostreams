require 'concurrent'
require 'fileutils'

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
  UTF8_ENCODING   = Encoding.find('UTF-8').freeze
  BINARY_ENCODING = Encoding.find('BINARY').freeze

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
    IOStreams.scheme(uri.scheme).new(path)
  end

  # For an existing IO Stream
  # IOStreams.io(io).file_name('blah.zip').encoding('BINARY').reader(&:read)
  # IOStreams.io(io).file_name('blah.zip').encoding('BINARY').each_line(...)
  # IOStreams.io(io).file_name('blah.csv.zip').each_line(...)
  # IOStreams.io(io).stream(:zip).stream(:pgp, passphrase: 'receiver_passphrase').reader(&:read)
  def self.io(io_stream)
    IOStreams::Stream.new(io_stream)
  end

  # For processing by either a file name or an open IO stream.
  def self.new(file_name_or_io)
    file_name_or_io.is_a?(String) ? path(file_name_or_io) : io(file_name_or_io)
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

  # DEPRECATED. Use `#path` or `#io`
  # Examples:
  #   IOStreams.path("data.zip").reader { |f| f.read(100) }
  #
  #   IOStreams.path(file_name).option(:encode, encoding: "BINARY").reader { |f| f.read(100) }
  #
  #   io_stream = StringIO.new("Hello World")
  #   IOStreams.io(io_stream).reader { |f| f.read(100) }
  def self.reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.reader(&block)
  end

  # DEPRECATED
  def self.each_line(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.each_line(**args, &block)
  end

  # DEPRECATED
  def self.each_row(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.each_row(**args, &block)
  end

  # DEPRECATED
  def self.each_record(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.each_record(**args, &block)
  end

  # DEPRECATED. Use `#path` or `#io`
  # Examples:
  #   IOStreams.path("data.zip").writer { |f| f.write("Hello World") }
  #
  #   IOStreams.path(file_name).option(:encode, encoding: "BINARY").writer { |f| f.write("Hello World") }
  #
  #   io_stream = StringIO.new("Hello World")
  #   IOStreams.io(io_stream).writer { |f| f.write("Hello World") }
  def self.writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.writer(&block)
  end

  # DEPRECATED
  def self.line_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.line_writer(**args, &block)
  end

  # DEPRECATED
  def self.row_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.row_writer(**args, &block)
  end

  # DEPRECATED
  def self.record_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.record_writer(**args, &block)
  end

  # Copies the source file/stream to the target file/stream.
  # Returns [Integer] the number of bytes copied
  #
  # Example: Copy between 2 files
  #   IOStreams.copy('a.csv', 'b.csv')
  #
  # Example: Read content from a Xlsx file and write it out in CSV form.
  #   IOStreams.copy('a.xlsx', 'b.csv')
  #
  # Example:
  #   # Read content from a JSON file and write it out in CSV form.
  #   #
  #   # The output header for the CSV file is extracted from the first row in the JSON file.
  #   # If the first JSON row does not contain all the column names then they will be ignored
  #   # for the rest of the file.
  #   IOStreams.copy('a.json', 'b.csv')
  #
  # Example:
  #   # Read a PSV file and write out a CSV file from it.
  #   IOStreams.copy('a.psv', 'b.csv')
  #
  # Example:
  #   # Copy between 2 files, encrypting the target file with Symmetric Encryption
  #   # Since the target file_name already includes `.enc` in the filename, it is automatically
  #   # encrypted.
  #   IOStreams.copy('a.csv', 'b.csv.enc')
  #
  # Example:
  #   # Copy between 2 files, encrypting the target file with Symmetric Encryption
  #   # Since the target file_name does not include `.enc` in the filename, to encrypt it
  #   # the encryption stream is added.
  #   IOStreams.copy('a.csv', 'b', target_options: [:enc])
  #
  # Example:
  #   # Copy between 2 files, encrypting the target file with Symmetric Encryption
  #   # Since the target file_name does not include `.enc` in the filename, to encrypt it
  #   # the encryption stream is added, along with the optional compression option.
  #   IOStreams.copy('a.csv', 'b', target_options: [enc: { compress: true }])
  #
  # Example:
  #   # Create a pgp encrypted file.
  #   # For PGP Encryption the recipients email address is required.
  #   IOStreams.copy('a.xlsx', 'b.csv.pgp', target_options: [:csv, pgp: { recipient_email: 'user@nospam.org' }])
  #
  # Example: Copy between 2 existing streams
  #   IOStreams.reader('a.csv') do |source_stream|
  #     IOStreams.writer('b.csv.enc') do |target_stream|
  #       IOStreams.copy(source_stream, target_stream)
  #     end
  #   end
  #
  # Example:
  #   # Copy between 2 csv files, reducing the number of columns present and encrypting the
  #   # target file with Symmetric Encryption
  #   output_headers = %w[name address]
  #   IOStreams.copy(
  #     'a.csv',
  #     'b.csv.enc',
  #     target_options: [csv:{headers: output_headers}, enc: {compress: true}]
  #   )
  #
  # Example:
  #   # Copy a locally encrypted file to AWS S3.
  #   # Decrypts the file, then compresses it with gzip as it is being streamed into S3.
  #   # Useful for when the entire bucket is encrypted on S3.
  #   IOStreams.copy('a.csv.enc', 's3://my_bucket/b.csv.gz')
  def self.copy(source_file_name_or_io, target_file_name_or_io, buffer_size: nil, source_options: {}, target_options: {})
    # TODO: prevent stream conversions when reader and writer streams are the same!
    reader(source_file_name_or_io, **source_options) do |source_stream|
      writer(target_file_name_or_io, **target_options) do |target_stream|
        IO.copy_stream(source_stream, target_stream)
      end
    end
  end

  # Returns [true|false] whether the supplied file_name_or_io is a reader stream
  def self.reader_stream?(file_name_or_io)
    file_name_or_io.respond_to?(:read)
  end

  # Returns [true|false] whether the supplied file_name_or_io is a reader stream
  def self.writer_stream?(file_name_or_io)
    file_name_or_io.respond_to?(:write)
  end

  # DEPRECATED. Use Path#compressed?
  def self.compressed?(file_name)
    Path.new(file_name).compressed?
  end

  # DEPRECATED. Use Path#encrypted?
  def self.encrypted?(file_name)
    Path.new(file_name).encrypted?
  end

  # DEPRECATED
  def self.line_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.line_reader(**args, &block)
  end

  # DEPRECATED
  def self.row_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.line_reader(**args, &block)
  end

  # DEPRECATED
  def self.record_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    path = build_path(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace)
    path.record_reader(**args, &block)
  end

  # Return named root path
  def self.root(root = :default)
    @root_paths[root.to_sym] || raise(ArgumentError, "Unknown root: #{root.inspect}")
  end

  # Add a named root path
  def self.add_root(root, *elements)
    raise(ArgumentError, "Invalid root name #{root.inspect}") unless root.to_s =~ /\A\w+\Z/

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
    @extensions
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
    @schemes
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

  def self.build_path(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil)
    path = new(file_name_or_io)
    path.file_name(file_name) if file_name

    apply_old_style_streams(path, streams) if streams

    if encoding || encode_cleaner || encode_replace
      if file_name_or_io.is_a?(String)
        path.option(:encode, encoding: encoding, cleaner: encode_cleaner, replace: encode_replace)
      else
        path.stream(:encode, encoding: encoding, cleaner: encode_cleaner, replace: encode_replace)
      end
    elsif !file_name_or_io.is_a?(String) && streams.nil?
      path.stream(:none)
    end

    path
  end

  # Applies old form streams to the path
  def self.apply_old_style_streams(path, streams)
    if streams.is_a?(Symbol)
      path.stream(streams)
    elsif streams.is_a?(Array)
      streams.each { |stream| apply_old_style_streams(path, stream) }
    elsif streams.is_a?(Hash)
      streams.each_pair { |stream, options| path.stream(stream, options) }
    else
      raise ArgumentError, "Invalid old style stream supplied: #{params.inspect}"
    end
  end

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
