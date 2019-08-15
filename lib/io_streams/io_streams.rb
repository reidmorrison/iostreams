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
  def self.reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
    stream(:reader, file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace, &block)
  end

  # Iterate over a file / stream returning one line at a time.
  # Embedded lines (within double quotes) will be skipped if
  #   1. The file name contains .csv
  #   2. Or the embedded_within argument is set
  #
  # Example: Supply custom options
  #   IOStreams.each_line(file_name, embedded_within: '"') do |line|
  #     puts line
  #   end
  #
  def self.each_line(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    line_reader(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace, **args) do |line_stream|
      line_stream.each(&block)
    end
  end

  # Iterate over a file / stream returning one line at a time.
  # Embedded lines (within double quotes) will be skipped if
  #   1. The file name contains .csv
  #   2. Or the embedded_within argument is set
  #
  # Example: Supply custom options
  #   IOStreams.each_row(file_name, embedded_within: '"') do |line|
  #     puts line
  #   end
  #
  def self.each_row(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    row_reader(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace, **args) do |row_stream|
      row_stream.each(&block)
    end
  end

  # Returns [Hash] of every record in a file or stream with support for headers.
  #
  # Reading a delimited stream and converting to tabular form.
  #
  # Each record / line is returned one at a time so that very large files
  # can be read without having to load the entire file into memory.
  #
  # Embedded lines (within double quotes) will be skipped if
  #   1. The file name contains .csv
  #   2. Or the embedded_within argument is set
  #
  # Example: Supply custom options
  #   IOStreams.each_record(file_name, embedded_within: '"') do |line|
  #     puts line
  #   end
  #
  # Example:
  #   file_name = 'customer_data.csv.pgp'
  #   IOStreams.each_record(file_name) do |hash|
  #     p hash
  #   end
  def self.each_record(file_name_or_io, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    record_reader(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace, **args) do |record_stream|
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
  def self.writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
    stream(:writer, file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace, &block)
  end

  def self.line_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Line::Writer) || file_name_or_io.is_a?(Array)

    writer(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace) do |io|
      IOStreams::Line::Writer.open(io, **args, &block)
    end
  end

  def self.row_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Row::Writer)

    line_writer(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace) do |io|
      file_name = file_name_or_io if file_name.nil? && file_name_or_io.is_a?(String)

      IOStreams::Row::Writer.open(io, file_name: file_name, **args, &block)
    end
  end

  def self.record_writer(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args, &block)
    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Record::Writer)

    line_writer(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace) do |io|
      file_name = file_name_or_io if file_name.nil? && file_name_or_io.is_a?(String)

      IOStreams::Record::Writer.open(io, file_name: file_name, **args, &block)
    end
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
  def self.copy(source_file_name_or_io, target_file_name_or_io, buffer_size: 65536, source_options: {}, target_options: {})
    bytes = 0
    reader(source_file_name_or_io, **source_options) do |source_stream|
      writer(target_file_name_or_io, **target_options) do |target_stream|
        while data = source_stream.read(buffer_size)
          break if data.size == 0
          bytes += data.size
          target_stream.write(data)
        end
      end
    end
    bytes
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

  # Returns [Array] the formats required to process the file by looking at
  # its extension(s)
  #
  # Example Zip file:
  #   IOStreams.streams_for_file_name('myfile.zip')
  #   => [ :zip ]
  #
  # Example Encrypted Gzip file:
  #   IOStreams.streams_for_file_name('myfile.csv.gz.enc')
  #   => [ :gz, :enc ]
  #
  # Example plain text / binary file:
  #   IOStreams.streams_for_file_name('myfile.csv')
  #   => []
  def self.streams_for_file_name(file_name)
    raise ArgumentError.new('File name cannot be nil') if file_name.nil?
    raise ArgumentError.new("File name must be a string: #{file_name.inspect}, class: #{file_name.class}") unless file_name.is_a?(String)

    parts      = ::File.basename(file_name).split('.')
    extensions = []
    while extension = parts.pop
      sym = extension.downcase.to_sym
      break unless @extensions[sym]
      extensions.unshift(sym)
    end
    extensions
  end

  # Extract URI if any was supplied
  def self.scheme_for_file_name(file_name)
    raise ArgumentError.new('File name cannot be nil') if file_name.nil?
    raise ArgumentError.new("File name must be a string: #{file_name.inspect}, class: #{file_name.class}") unless file_name.is_a?(String)

    if matches = file_name.match(/\A(\w+):\/\//)
      matches[1].downcase.to_sym
    end
  end

  # Iterate over a file / stream returning each record/line one at a time.
  # It will apply the embedded_within argument if the file or input_stream contain .csv in its name.
  def self.line_reader(file_name_or_io, streams: nil, file_name: nil, encoding: nil, encode_cleaner: nil, encode_replace: nil, embedded_within: nil, **args, &block)

    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Line::Reader) || file_name_or_io.is_a?(Array)

    # TODO: needs to be improved
    if embedded_within.nil? && file_name_or_io.is_a?(String)
      embedded_within = '"' if file_name_or_io.include?('.csv')
    elsif embedded_within.nil? && file_name
      embedded_within = '"' if file_name.include?('.csv')
    end

    reader(file_name_or_io, streams: streams, file_name: file_name, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace) do |io|
      IOStreams::Line::Reader.open(io, embedded_within: embedded_within, **args, &block)
    end
  end

  # Iterate over a file / stream returning each line as an array, one at a time.
  def self.row_reader(file_name_or_io,
    streams: nil,
    delimiter: nil,
    file_name: nil,
    encoding: nil,
    encode_cleaner: nil,
    encode_replace: nil,
    embedded_within: nil,
    **args,
    &block)

    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Row::Reader)

    line_reader(
      file_name_or_io,
      streams:         streams,
      delimiter:       delimiter,
      file_name:       file_name,
      encoding:        encoding,
      encode_cleaner:  encode_cleaner,
      encode_replace:  encode_replace,
      embedded_within: embedded_within
    ) do |io|
      file_name = file_name_or_io if file_name.nil? && file_name_or_io.is_a?(String)
      IOStreams::Row::Reader.open(io, file_name: file_name, **args, &block)
    end
  end

  # Iterate over a file / stream returning each line as a hash, one at a time.
  def self.record_reader(file_name_or_io,
    streams: nil,
    delimiter: nil,
    file_name: nil,
    encoding: nil,
    encode_cleaner: nil,
    encode_replace: nil,
    embedded_within: nil,
    **args,
    &block)

    return yield(file_name_or_io) if file_name_or_io.is_a?(IOStreams::Record::Reader)

    line_reader(file_name_or_io,
                streams:         streams,
                delimiter:       delimiter,
                file_name:       file_name,
                encoding:        encoding,
                encode_cleaner:  encode_cleaner,
                encode_replace:  encode_replace,
                embedded_within: embedded_within
    ) do |io|


      file_name = file_name_or_io if file_name.nil? && file_name_or_io.is_a?(String)
      IOStreams::Record::Reader.open(io, file_name: file_name, **args, &block)
    end
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

  # Register a file extension and the reader and writer streaming classes
  #
  # Example:
  #   # MyXls::Reader and MyXls::Writer must implement .open
  #   register_extension(:xls, MyXls::Reader, MyXls::Writer)
  def self.register_scheme(scheme, reader_class, writer_class)
    raise(ArgumentError, "Invalid scheme #{scheme.inspect}") unless scheme.nil? || scheme.to_s =~ /\A\w+\Z/
    @schemes[scheme.nil? ? nil : scheme.to_sym] = Extension.new(reader_class, writer_class)
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

  # Used by writers that can write directly to file to create the target path
  def self.mkpath(file_name)
    path = ::File.dirname(file_name)
    FileUtils.mkdir_p(path) unless ::File.exist?(path)
  end

  private

  # A registry to hold formats for processing files during upload or download
  @extensions = {}
  @schemes    = {}

  # Struct to hold the Stream and options if any
  StreamStruct = Struct.new(:klass, :options)

  # Returns a reader or writer stream
  def self.stream(type, file_name_or_io, streams:, file_name:, encoding: nil, encode_cleaner: nil, encode_replace: nil, &block)
    raise(ArgumentError, 'IOStreams call is missing mandatory block') if block.nil?

    streams = streams_for_file_name(file_name) if streams.nil? && file_name

    # Shortcut for when it is already a stream
    if !file_name_or_io.is_a?(String) && (streams.nil? || streams.empty?)
      if encoding || encode_cleaner || encode_replace
        return IOStreams::Encode::Reader.open(file_name_or_io, encoding: encoding, encode_cleaner: encode_cleaner, encode_replace: encode_replace, &block)
      else
        return block.call(file_name_or_io)
      end
    end

    if streams.nil?
      streams = file_name_or_io.is_a?(String) ? streams_for_file_name(file_name_or_io) : [nil]
    end
    scheme = scheme_for_file_name(file_name_or_io) if file_name_or_io.is_a?(String)

    stream_structs = streams_for(type, streams)
    stream_structs << stream_struct_for_scheme(type, scheme) if stream_structs.empty? || scheme

    # Add encoding stream if any of its options are present
    if encoding || encode_cleaner || encode_replace
      klass                    = type == :reader ? IOStreams::Encode::Reader : IOStreams::Encode::Writer
      options                  = {}
      options[:encoding]       = encoding if encoding
      options[:encode_cleaner] = encode_cleaner if encode_cleaner
      options[:encode_replace] = encode_replace if encode_replace
      stream_structs.unshift(StreamStruct.new(klass, options))
    end

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

  def self.stream_struct_for_scheme(type, scheme, options = {})
    ext   = @schemes[scheme.nil? ? nil : scheme.to_sym] || raise(ArgumentError, "Unknown Scheme type: #{scheme.inspect}")
    klass = ext.send("#{type}_class")
    StreamStruct.new(klass, options)
  end

  # Default reader/writer when no other streams need to be applied.
  # register_extension(nil, IOStreams::File::Reader, IOStreams::File::Writer)

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

  # Support URI schemes
  #
  # Examples:
  #    path/file_name
  #    http://hostname/path/file_name
  #    https://hostname/path/file_name
  #    sftp://hostname/path/file_name
  #    s3://bucket/key
  register_scheme(nil, IOStreams::File::Reader, IOStreams::File::Writer)
  # register_scheme(:http,  IOStreams::HTTP::Reader,  IOStreams::HTTP::Writer)
  # register_scheme(:https, IOStreams::HTTPS::Reader, IOStreams::HTTPS::Writer)
  # register_scheme(:sftp,  IOStreams::SFTP::Reader,  IOStreams::SFTP::Writer)
  register_scheme(:s3, IOStreams::S3::Reader, IOStreams::S3::Writer)
end
