require 'concurrent'

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

  # Returns a Reader for reading a file / stream
  #
  # Parameters
  #   file_name_or_io [String|IO]
  #     The file_name of the file to write to, or an IO Stream that implements
  #     #read.
  #
  #   streams [Symbol|Array]
  #     The formats/streams that be used to convert the data whilst it is
  #     being read.
  #     When nil, the file_name will be inspected to try and determine what
  #     streams should be applied.
  #     Default: nil
  #
  #   file_name [String]
  #     When `streams` is not supplied, `file_name` can be used for determining the streams
  #     to apply to read the file/stream.
  #     This is particularly useful when `file_name_or_io` is a stream, or a temporary file name.
  #     Default: nil
  #
  # Example: Zip
  #   IOStreams.reader('myfile.zip') do |stream|
  #     puts stream.read
  #   end
  #
  # Example: Encrypted Zip
  #   IOStreams.reader('myfile.zip.enc') do |stream|
  #     puts stream.read
  #   end
  #
  # Example: Explicitly set the streams
  #   IOStreams.reader('myfile.zip.enc', [:zip, :enc]) do |stream|
  #     puts stream.read
  #   end
  #
  # Example: Supply custom options
  #   # Encrypt the file and get Symmetric Encryption to also compress it
  #   IOStreams.reader('myfile.csv.enc', streams: enc: {compress: true}) do |stream|
  #     puts stream.read
  #   end
  #
  # Note:
  # * Passes the file_name_or_io as-is into the block if it is already a reader stream AND
  #   no streams are passed in.
  def self.reader(file_name_or_io, streams: nil, file_name: nil, &block)
    stream(:reader, file_name_or_io, streams: streams, file_name: file_name, &block)
  end

  # Iterate over a file / stream returning one line at a time.
  def self.each_line(file_name_or_io, **args, &block)
    line_reader(file_name_or_io, **args) do |line_stream|
      line_stream.each(&block)
    end
  end

  # Returns [Hash] of every record in a file or stream with support for headers.
  #
  # Reading a delimited stream and converting to tabular form.
  #
  # Each record / line is returned one at a time so that very large files
  # can be read without having to load the entire file into memory.
  #
  # Example:
  #   file_name = 'customer_data.csv.pgp'
  #   IOStreams.each_record(file_name) do |hash|
  #     p hash
  #   end
  def self.each_record(file_name_or_io, **args, &block)
    record_reader(file_name_or_io,**args) do |record_stream|
      record_stream.each(&block)
    end
  end

  # Returns a Writer for writing to a file / stream
  #
  # Parameters
  #   file_name_or_io [String|IO]
  #     The file_name of the file to write to, or an IO Stream that implements
  #     #write.
  #
  #   streams [Symbol|Array]
  #     The formats/streams that be used to convert the data whilst it is
  #     being written.
  #     When nil, the file_name will be inspected to try and determine what
  #     streams should be applied.
  #     Default: nil
  #
  # Stream types / extensions supported:
  #   .zip       Zip File                                   [ :zip ]
  #   .gz, .gzip GZip File                                  [ :gzip ]
  #   .enc       File Encrypted using symmetric encryption  [ :enc ]
  #   other      All other extensions will be returned as:  [ :file ]
  #
  # When a file is encrypted, it may also be compressed:
  #   .zip.enc  [ :zip, :enc ]
  #   .gz.enc   [ :gz,  :enc ]
  #
  # Example: Zip
  #   IOStreams.writer('myfile.zip') do |stream|
  #     stream.write(data)
  #   end
  #
  # Example: Encrypted Zip
  #   IOStreams.writer('myfile.zip.enc') do |stream|
  #     stream.write(data)
  #   end
  #
  # Example: Explicitly set the streams
  #   IOStreams.writer('myfile.zip.enc', [:zip, :enc]) do |stream|
  #     stream.write(data)
  #   end
  #
  # Example: Supply custom options
  #   IOStreams.writer('myfile.csv.enc', [enc: { compress: true }]) do |stream|
  #     stream.write(data)
  #   end
  #
  # Example: Set internal filename when creating a zip file
  #   IOStreams.writer('myfile.csv.zip', zip: { zip_file_name: 'myfile.csv' }) do |stream|
  #     stream.write(data)
  #   end
  #
  # Note:
  # * Passes the file_name_or_io as-is into the block if it is already a writer stream AND
  #   no streams are passed in.
  def self.writer(file_name_or_io, streams: nil, file_name: nil, &block)
    stream(:writer, file_name_or_io, streams: streams, file_name: file_name, &block)
  end

  def self.line_writer(file_name_or_io, streams: nil, file_name: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Line::Writer) || file_name_or_io.is_a?(Array)

    writer(file_name_or_io, streams: streams, file_name: file_name) do |io|
      IOStreams::Line::Writer.open(io, **args, &block)
    end
  end

  def self.row_writer(file_name_or_io, streams: nil, file_name: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Row::Writer)

    line_writer(file_name_or_io, streams: streams, file_name: file_name) do |io|
      IOStreams::Row::Writer.open(io, **args, &block)
    end
  end

  def self.record_writer(file_name_or_io, streams: nil, file_name: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Record::Writer)

    line_writer(file_name_or_io, streams: streams, file_name: file_name) do |io|
      IOStreams::Record::Writer.open(io, **args, &block)
    end
  end

  # Copies the source file/stream to the target file/stream.
  # Returns [Integer] the number of bytes copied
  #
  # Example: Copy between 2 files
  #   IOStreams.copy('a.csv', 'b.csv')
  #   # TODO: The above will convert the csv file to a Hash and then back to write it to the target file.
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
  def self.copy(source_file_name_or_io, target_file_name_or_io, buffer_size: 65536, source_options: {}, target_options: {})
    reader(source_file_name_or_io, **source_options) do |source_stream|
      writer(target_file_name_or_io, **target_options) do |target_stream|
        bytes = 0
        while data = source_stream.read(buffer_size)
          break if data.size == 0
          bytes += data.size
          target_stream.write(data)
        end
        bytes
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

  # Returns [true|false] whether the file is compressed.
  # Note: Currently only looks at the file name extension
  def self.compressed?(file_name)
    !(file_name =~ /\.(zip|gz|gzip|xls.|)\z/i).nil?
  end

  # Returns [true|false] whether the file is encrypted.
  # Note: Currently only looks at the file name extension
  def self.encrypted?(file_name)
    !(file_name =~ /\.(enc|pgp|gpg)\z/i).nil?
  end

  # Deletes the specified stream from the supplied streams if present
  # Returns deleted stream, or nil if not found
  def self.delete_stream(stream, streams)
    raise(ArgumentError, "Argument :stream must be a symbol: #{stream.inspect}") unless stream.is_a?(Symbol)

    Array(streams).delete_if do |_stream|
      stream_key = _stream.is_a?(Symbol) ? _stream : _stream.keys.first
      stream == stream_key
    end
  end

  # Returns [Array] the formats required to process the file by looking at
  # its extension(s)
  #
  # Example Zip file:
  #   RocketJob::Formatter::Formats.streams_for_file_name('myfile.zip')
  #   => [ :zip ]
  #
  # Example Encrypted Gzip file:
  #   RocketJob::Formatter::Formats.streams_for_file_name('myfile.csv.gz.enc')
  #   => [ :gz, :enc ]
  #
  # Example plain text / binary file:
  #   RocketJob::Formatter::Formats.streams_for_file_name('myfile.csv')
  #   => [ :file ]
  def self.streams_for_file_name(file_name)
    raise ArgumentError.new('File name cannot be nil') if file_name.nil?
    raise ArgumentError.new("File name must be a string: #{file_name.inspect}, class: #{file_name.class}") unless file_name.is_a?(String)
    parts      = file_name.split('.')
    extensions = []
    while extension = parts.pop
      sym = extension.downcase.to_sym
      break unless @extensions[sym]
      extensions.unshift(sym)
    end
    extensions
  end

  Extension = Struct.new(:reader_class, :writer_class)

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

  private

  # A registry to hold formats for processing files during upload or download
  @extensions = {}

  # Struct to hold the Stream and options if any
  StreamStruct = Struct.new(:klass, :options)

  # Iterate over a file / stream returning each record/line one at a time.
  def self.line_reader(file_name_or_io, streams: nil, file_name: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Line::Reader) ||
      file_name_or_io.is_a?(IOStreams::Xlsx::Reader) ||
      file_name_or_io.is_a?(Array)

    reader(file_name_or_io, streams: streams, file_name: file_name) do |io|
      IOStreams::Line::Reader.open(io, **args, &block)
    end
  end

  # Iterate over a file / stream returning each line as a hash, one at a time.
  def self.record_reader(file_name_or_io,
    streams: nil,
    delimiter: nil,
    encoding: IOStreams::UTF8_ENCODING,
    strip_non_printable: false,
    file_name: nil,
    **args,
    &block)

    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Record::Reader)

    # TODO: When a file_name is supplied extract the tabular format from the filename. E.g. .csv, .json, etc.

    line_reader(
      streams:             streams,
      delimiter:           delimiter,
      encoding:            encoding,
      strip_non_printable: strip_non_printable,
      file_name:           file_name) do |io|

      IOStreams::Record::Reader.open(io, file_name: file_name, **args, &block)
    end
  end

  # Returns a reader or writer stream
  def self.stream(type, file_name_or_io, streams:, file_name:, &block)
    # TODO: Add support for different schemes, such as file://, s3://, sftp://

    streams = streams_for_file_name(file_name) if streams.nil? && file_name

    # Shortcut for when it is already a stream and no further streams need to be applied.
    return block.call(file_name_or_io) if !file_name_or_io.is_a?(String) && (streams.nil? || streams.empty?)

    if streams.nil?
      streams = file_name_or_io.is_a?(String) ? streams_for_file_name(file_name_or_io) : [nil]
    end

    stream_structs = streams_for(type, streams)
    if stream_structs.size == 1
      stream_struct = stream_structs.first
      stream_struct.klass.open(file_name_or_io, stream_struct.options, &block)
    else
      # Daisy chain multiple streams together
      last = stream_structs.inject(block) { |inner, ss| -> io { ss.klass.open(io, ss.options, &inner) } }
      last.call(file_name_or_io)
    end
  end

  # type: :reader or :writer
  def self.streams_for(type, params)
    if params.is_a?(Symbol)
      [stream_struct_for_stream(type, params)]
    elsif params.is_a?(Array)
      return [stream_struct_for_stream(type, nil)] if params.empty?
      a = []
      params.each do |stream|
        if stream.is_a?(Hash)
          stream.each_pair { |stream_sym, options| a << stream_struct_for_stream(type, stream_sym, options) }
        else
          a << stream_struct_for_stream(type, stream)
        end
      end
      a
    elsif params.is_a?(Hash)
      a = []
      params.each_pair { |stream, options| a << stream_struct_for_stream(type, stream, options) }
      a
    else
      raise ArgumentError, "Invalid params supplied: #{params.inspect}"
    end
  end

  def self.stream_struct_for_stream(type, stream, options = {})
    ext   = @extensions[stream.nil? ? nil : stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
    klass = ext.send("#{type}_class")
    StreamStruct.new(klass, options)
  end

  # Default reader/writer when no other streams need to be applied.
  register_extension(nil,   IOStreams::File::Reader,     IOStreams::File::Writer)

  # Register File extensions
  register_extension(:bz2,  IOStreams::Bzip2::Reader,    IOStreams::Bzip2::Writer)
  register_extension(:gz,   IOStreams::Gzip::Reader,     IOStreams::Gzip::Writer)
  register_extension(:gzip, IOStreams::Gzip::Reader,     IOStreams::Gzip::Writer)
  register_extension(:zip,  IOStreams::Zip::Reader,      IOStreams::Zip::Writer)
  register_extension(:pgp,  IOStreams::Pgp::Reader,      IOStreams::Pgp::Writer)
  register_extension(:gpg,  IOStreams::Pgp::Reader,      IOStreams::Pgp::Writer)
  register_extension(:xlsx, IOStreams::Xlsx::Reader, nil)
  register_extension(:xlsm, IOStreams::Xlsx::Reader, nil)

  # Use Symmetric Encryption to encrypt of decrypt files with the `enc` extension
  # when the gem `symmetric-encryption` has been loaded.
  if defined?(SymmetricEncryption)
    register_extension(:enc,  SymmetricEncryption::Reader, SymmetricEncryption::Writer)
  end

  # register_scheme(nil,    IOStreams::File::Reader,  IOStreams::File::Writer)
  # register_scheme(:file,  IOStreams::File::Reader,  IOStreams::File::Writer)
  # register_scheme(:http,  IOStreams::HTTP::Reader,  IOStreams::HTTP::Writer)
  # register_scheme(:https, IOStreams::HTTPS::Reader, IOStreams::HTTPS::Writer)
  # register_scheme(:sftp,  IOStreams::SFTP::Reader,  IOStreams::SFTP::Writer)
  # register_scheme(:s3,    IOStreams::S3::Reader,    IOStreams::S3::Writer)
end
