require 'concurrent'
module IOStreams
  # A registry to hold formats for processing files during upload or download
  @extensions = Concurrent::Map.new

  UTF8_ENCODING   = Encoding.find('UTF-8').freeze
  BINARY_ENCODING = Encoding.find('BINARY').freeze

  # Returns [Array] the formats required to process the file by looking at
  # its extension(s)
  #
  # Extensions supported:
  #   .zip       Zip File                                      [ :zip ]
  #   .gz, .gzip GZip File                                     [ :gzip ]
  #   .enc       File Encrypted using symmetric encryption     [ :enc ]
  #   etc...
  #   other      Unrecognized extensions will be returned as:  []
  #
  # When a file is encrypted, it may also be compressed:
  #   .zip.enc  [ :zip, :enc ]
  #   .gz.enc   [ :gz,  :enc ]
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

  # Register a file extension and the reader and writer classes to use to format it
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
  #   IOStreams.reader('myfile.csv.enc', [:enc]) do |stream|
  #     puts stream.read
  #   end
  #
  # Note:
  # * Passes the file_name_or_io as-is into the block if it is already a reader stream AND
  #   no streams are passed in.
  def self.reader(file_name_or_io, streams = nil, &block)
    return block.call(file_name_or_io) if streams.nil? && IOStreams.reader_stream?(file_name_or_io)

    stream(:reader, file_name_or_io, streams, &block)
  end

  # Iterate over a file / stream returning each record/line one at a time.
  def self.each(file_name_or_io,
    streams: nil,
    delimiter: nil,
    encoding: IOStreams::UTF8_ENCODING,
    strip_non_printable: false,
    exclude_streams: nil,
    file_name: nil,
    &block)

    # file_name, if supplied contains the original file_name from which the streams need to be derived.
    file_name = file_name_or_io if file_name.nil? && !IOStreams.reader_stream?(file_name_or_io)
    streams   ||= IOStreams.streams_for_file_name(file_name) if file_name

    Array(exclude_streams).each { |stream| delete_stream(stream, streams) } if exclude_streams

    streams.unshift(delimited: {delimiter: delimiter, encoding: encoding, strip_non_printable: strip_non_printable}) unless IOStreams.delimited_stream?(streams)

    reader(file_name_or_io, streams) { |io| io.each(&block) }
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
  #   IOStreams.tabular_reader(file_name) do |record|
  #     p record
  #   end
  def self.tabular_reader(file_name_or_io, format: :csv, strip_non_printable: true, **args)
    tabular        = Tabular::Tabular.new(format: format)
    process_header = tabular.parse_header?

    delimited_reader(file_name_or_io, strip_non_printable: strip_non_printable, **args) do |delimited_io|
      delimited_io.each do |line|
        if process_header
          process_header = false
          tabular.parse_header(line)
        else
          yield(tabular.parse(line))
        end
      end
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
  def self.writer(file_name_or_io, streams = nil, &block)
    return block.call(file_name_or_io) if streams.nil? && IOStreams.writer_stream?(file_name_or_io)

    stream(:writer, file_name_or_io, streams, &block)
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
  #
  # TODO: Need ability to disable csv parsing since we don't want to parse csv to only render csv again.
  # TODO: On the other hand it would be great to be able to ETL map between CSV files.
  def self.copy(source_file_name_or_io, target_file_name_or_io, buffer_size: 65536, source_options: nil, target_options: nil)
    reader(source_file_name_or_io, source_options) do |source_stream|
      writer(target_file_name_or_io, target_options) do |target_stream|
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

  # Returns [true|false] whether the stream starts with a delimited reader or writer
  def self.delimited_stream?(streams)
    stream = Array(streams).first
    return false unless stream

    # TODO Need to figure out a way so that this is not hard-coded
    [:xlsx, :xlsm, :delimited].include?(stream.is_a?(Symbol) ? stream : stream.keys.first)
  end

  ##########################################################################

  private

  # Struct to hold the Stream and options if any
  StreamStruct = Struct.new(:klass, :options)

  # Returns a reader or writer stream
  def self.stream(type, file_name_or_io, streams = nil, &block)
    unless streams
      respond_to = type == :reader ? :read : :write
      streams    = file_name_or_io.respond_to?(respond_to) ? [nil] : streams_for_file_name(file_name_or_io)
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

  # Register File extensions
  # @formatter:off
  register_extension(nil,   IOStreams::File::Reader,     IOStreams::File::Writer)
  register_extension(:enc,  SymmetricEncryption::Reader, SymmetricEncryption::Writer) if defined?(SymmetricEncryption)
  register_extension(:bz2,  IOStreams::Bzip2::Reader,    IOStreams::Bzip2::Writer)
  register_extension(:gz,   IOStreams::Gzip::Reader,     IOStreams::Gzip::Writer)
  register_extension(:gzip, IOStreams::Gzip::Reader,     IOStreams::Gzip::Writer)
  register_extension(:zip,  IOStreams::Zip::Reader,      IOStreams::Zip::Writer)
  register_extension(:pgp,  IOStreams::Pgp::Reader,      IOStreams::Pgp::Writer)
  register_extension(:gpg,  IOStreams::Pgp::Reader,      IOStreams::Pgp::Writer)

  # Needed to wrap with delimited
  register_extension(:delimited, IOStreams::Delimited::Reader, IOStreams::Delimited::Writer)

  # Tabular Streams
  register_extension(:csv,  IOStreams::CSV::Reader,  IOStreams::CSV::Writer)
  # register_extension(:json, IOStreams::JSON::Reader, IOStreams::JSON::Writer)
  # register_extension(:psv,  IOStreams::PSV::Reader,  IOStreams::PSV::Writer)
  register_extension(:xlsx, IOStreams::Xlsx::Reader, nil)
  register_extension(:xlsm, IOStreams::Xlsx::Reader, nil)

  # register_scheme(nil,    IOStreams::File::Reader,  IOStreams::File::Writer)
  # register_scheme(:file,  IOStreams::File::Reader,  IOStreams::File::Writer)
  # register_scheme(:http,  IOStreams::HTTP::Reader,  IOStreams::HTTP::Writer)
  # register_scheme(:https, IOStreams::HTTPS::Reader, IOStreams::HTTPS::Writer)
  # register_scheme(:sftp,  IOStreams::SFTP::Reader,  IOStreams::SFTP::Writer)
  # register_scheme(:s3,    IOStreams::S3::Reader,    IOStreams::S3::Writer)
end
