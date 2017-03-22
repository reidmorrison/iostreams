require 'concurrent'
module IOStreams
  # A registry to hold formats for processing files during upload or download
  @@extensions = Concurrent::Map.new

  UTF8_ENCODING   = Encoding.find('UTF-8').freeze
  BINARY_ENCODING = Encoding.find('BINARY').freeze

  # Returns [Array] the formats required to process the file by looking at
  # its extension(s)
  #
  # Extensions supported:
  #   .zip       Zip File                                   [ :zip ]
  #   .gz, .gzip GZip File                                  [ :gzip ]
  #   .enc       File Encrypted using symmetric encryption  [ :enc ]
  #   other      All other extensions will be returned as:  [ :file ]
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
      break unless @@extensions[extension.to_sym]
      extensions.unshift(extension.to_sym)
    end
    extensions << :file if extensions.size == 0
    extensions
  end

  Extension = Struct.new(:reader_class, :writer_class)

  # Register a file extension and the reader and writer classes to use to format it
  #
  # Example:
  #   # MyXls::Reader and MyXls::Writer must implement .open
  #   register_extension(:xls, MyXls::Reader, MyXls::Writer)
  def self.register_extension(extension, reader_class, writer_class)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.to_s =~ /\A\w+\Z/
    @@extensions[extension.to_sym] = Extension.new(reader_class, writer_class)
  end

  # De-Register a file extension
  #
  # Returns [Symbol] the extension removed, or nil if the extension was not registered
  #
  # Example:
  #   register_extension(:xls)
  def self.deregister_extension(extension)
    raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.to_s =~ /\A\w+\Z/
    @@extensions.delete(extension.to_sym)
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
  def self.reader(file_name_or_io, streams = nil, &block)
    stream(:reader, file_name_or_io, streams, &block)
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
  def self.writer(file_name_or_io, streams = nil, &block)
    stream(:writer, file_name_or_io, streams, &block)
  end

  # Copies the source stream to the target stream
  # Returns [Integer] the number of bytes copied
  #
  # Example:
  #   IOStreams.reader('a.csv') do |source_stream|
  #     IOStreams.writer('b.csv.enc') do |target_stream|
  #       IOStreams.copy(source_stream, target_stream)
  #     end
  #   end
  def self.copy(source_stream, target_stream, buffer_size=65536)
    bytes = 0
    while data = source_stream.read(buffer_size)
      break if data.size == 0
      bytes += data.size
      target_stream.write(data)
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

  # Returns [true|false] whether the file is compressed
  # Note: Currently only looks at the file name extension
  def self.compressed?(file_name)
    !(file_name =~ /\.(zip|gz|gzip|xls.|)\z/i).nil?
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
      streams    = file_name_or_io.respond_to?(respond_to) ? [:file] : streams_for_file_name(file_name_or_io)
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

  def self.stream_struct_for_stream(type, stream, options={})
    ext   = @@extensions[stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
    klass = ext.send("#{type}_class")
    StreamStruct.new(klass, options)
  end

  # Register File extensions
  # @formatter:off
  register_extension(:enc,       SymmetricEncryption::Reader,  SymmetricEncryption::Writer) if defined?(SymmetricEncryption)
  register_extension(:file,      IOStreams::File::Reader,      IOStreams::File::Writer)
  register_extension(:gz,        IOStreams::Gzip::Reader,      IOStreams::Gzip::Writer)
  register_extension(:gzip,      IOStreams::Gzip::Reader,      IOStreams::Gzip::Writer)
  register_extension(:zip,       IOStreams::Zip::Reader,       IOStreams::Zip::Writer)
  register_extension(:delimited, IOStreams::Delimited::Reader, IOStreams::Delimited::Writer)
  register_extension(:xlsx,      IOStreams::Xlsx::Reader,      nil)
  register_extension(:xlsm,      IOStreams::Xlsx::Reader,      nil)
  register_extension(:pgp,       IOStreams::Pgp::Reader,       IOStreams::Pgp::Writer)
  register_extension(:gpg,       IOStreams::Pgp::Reader,       IOStreams::Pgp::Writer)
  #register_extension(:csv,       IOStreams::CSV::Reader,       IOStreams::CSV::Writer)
end
