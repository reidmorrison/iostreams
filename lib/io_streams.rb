module RocketJob
  module Streams
    autoload :FileReader, 'rocket_job/streams/file_reader'
    autoload :FileWriter, 'rocket_job/streams/file_writer'
    autoload :GzipReader, 'rocket_job/streams/gzip_reader'
    autoload :GzipWriter, 'rocket_job/streams/gzip_writer'
    autoload :ZipReader,  'rocket_job/streams/zip_reader'
    autoload :ZipWriter,  'rocket_job/streams/zip_writer'

    # A registry to hold formats for processing files during upload or download
    @@extensions = ThreadSafe::Hash.new

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
      raise ArgumentError.new("RocketJob Cannot detect file format when uploading a stream") unless file_name.is_a?(String)
      parts = file_name.split('.')
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
      raise "Invalid extension #{extension.inspect}" unless extension.to_s =~ /\A\w+\Z/
      @@extensions[extension.to_sym] = Extension.new(reader_class, writer_class)
    end

    # De-Register a file extension
    #
    # Returns [Symbol] the extension removed, or nil if the extension was not registered
    #
    # Example:
    #   register_extension(:xls)
    def self.deregister_extension(extension)
      raise "Invalid extension #{extension.inspect}" unless extension.to_s =~ /\A\w+\Z/
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
    #   RocketJob::Streams.reader('myfile.zip') do |stream|
    #     puts stream.read
    #   end
    #
    # Example: Encrypted Zip
    #   RocketJob::Streams.reader('myfile.zip.enc') do |stream|
    #     puts stream.read
    #   end
    #
    # Example: Explicitly set the streams
    #   RocketJob::Streams.reader('myfile.zip.enc', [:zip, :enc]) do |stream|
    #     puts stream.read
    #   end
    #
    # Example: Supply custom options
    #   # Encrypt the file and get Symmetric Encryption to also compress it
    #   RocketJob::Streams.reader('myfile.csv.enc', [:enc]) do |stream|
    #     puts stream.read
    #   end
    def self.reader(file_name_or_io, streams=nil, &block)
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
    #   RocketJob::Streams.writer('myfile.zip') do |stream|
    #     stream.write(data)
    #   end
    #
    # Example: Encrypted Zip
    #   RocketJob::Streams.writer('myfile.zip.enc') do |stream|
    #     stream.write(data)
    #   end
    #
    # Example: Explicitly set the streams
    #   RocketJob::Streams.writer('myfile.zip.enc', [:zip, :enc]) do |stream|
    #     stream.write(data)
    #   end
    #
    # Example: Supply custom options
    #   RocketJob::Streams.writer('myfile.csv.enc', [enc: { compress: true }]) do |stream|
    #     stream.write(data)
    #   end
    def self.writer(file_name_or_io, streams=nil, &block)
      stream(:writer, file_name_or_io, streams, &block)
    end

    # Copies the source stream to the target stream
    # Returns [Integer] the number of bytes copied
    #
    # Example:
    #   RocketJob::Streams.reader('a.csv') do |source_stream|
    #     RocketJob::Streams.writer('b.csv.enc') do |target_stream|
    #       RocketJob::Streams.copy(source_stream, target_stream)
    #     end
    #   end
    def self.copy(source_stream, target_stream, buffer_size=65536)
      bytes = 0
      loop do
        data = source_stream.read(buffer_size)
        break unless data
        bytes += data.size
        target_stream.write(data)
      end
      bytes
    end

    ##########################################################################
    private

    # Struct to hold the Stream and options if any
    StreamStruct = Struct.new(:klass, :options)

    # Returns a reader or writer stream
    def self.stream(type, file_name_or_io, streams=nil, &block)
      unless streams
        streams = file_name_or_io.is_a?(String) ? streams_for_file_name(file_name_or_io) : [ :file ]
      end
      stream_structs = streams_for(type, streams)
      if stream_structs.size == 1
        stream_struct = stream_structs.first
        stream_struct.klass.open(file_name_or_io, stream_struct.options, &block)
      else
        # Daisy chain multiple streams together
        last = stream_structs.inject(block){ |inner, stream_struct| -> io { stream_struct.klass.open(io, stream_struct.options, &inner) } }
        last.call(file_name_or_io)
      end
    end

    # type: :reader or :writer
    def self.streams_for(type, params)
      if params.is_a?(Symbol)
        [ stream_struct_for_stream(type, params) ]
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

    register_extension(:enc,  SymmetricEncryption::Reader, SymmetricEncryption::Writer)
    register_extension(:file, Streams::FileReader,         Streams::FileWriter)
    register_extension(:gz,   Streams::GzipReader,         Streams::GzipWriter)
    register_extension(:gzip, Streams::GzipReader,         Streams::GzipWriter)
    register_extension(:zip,  Streams::ZipReader,          Streams::ZipWriter)
  end
end