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
    # Example:
    #   RocketJob::Formatter::Formats.streams_for_file_name('myfile.zip')
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

    # Returns [Array] list of stream readers matching the supplied list
    def self.readers_for(params)
      streams_for(params, :reader)
    end

    # Returns [Array] list of stream readers matching the supplied list
    def self.writers_for(params)
      streams_for(params, :writer)
    end

    Extension = Struct.new(:reader_class, :writer_class)

    # Register a file extension and the reader and writer classes to use to format it
    def self.register_extension(extension, reader_class, writer_class)
      raise "Invalid extension #{extension.inspect}" unless extension.to_s =~ /\A\w+\Z/
      @@extensions[extension.to_sym] = Extension.new(reader_class, writer_class)
    end

    # De-Register a file extension
    def self.deregister_extension(extension)
      raise "Invalid extension #{extension.inspect}" unless extension.to_s =~ /\A\w+\Z/
      @@extensions.delete(extension.to_sym)
    end

    # Returns a Reader for reading a file by checking its extension for supported
    # conversions, or an explicit list of streams to apply to this reader
    def self.reader(file_name_or_io, streams=nil, &block)
      unless streams
        raise ArgumentError.new("RocketJob Cannot detect the format when reading from a stream") unless file_name_or_io.is_a?(String)
        streams = streams_for_file_name(file_name_or_io)
      end
      stream_classes = readers_for(streams)
      if stream_classes.size == 1
        stream_classes.first.open(file_name_or_io, &block)
      else
        # Daisy chain multiple streams together
        last = stream_classes.inject(block){ |inner, stream_class| -> io { stream_class.open(io, &inner) } }
        last.call(file_name_or_io)
      end
    end

    # Returns a Reader for reading a file by checking its extension for supported
    # conversions, or an explicit list of streams to apply to this reader
    def self.writer(file_name_or_io, streams=nil, &block)
      unless streams
        raise ArgumentError.new("RocketJob Cannot detect the format when writing to a stream") unless file_name_or_io.is_a?(String)
        streams = streams_for_file_name(file_name_or_io)
      end
      stream_classes = writers_for(streams)
      if stream_classes.size == 1
        stream_classes.first.open(file_name_or_io, &block)
      else
        # Daisy chain multiple streams together
        last = stream_classes.inject(block){ |inner, stream_class| -> io { stream_class.open(io, &inner) } }
        last.call(file_name_or_io)
      end
    end

    ##########################################################################
    private

    # type: :reader or :writer
    def self.streams_for(params, type)
      if params.is_a?(Symbol)
        [ ( @@extensions[params] || raise(ArgumentError, "Unknown Stream type: #{params.inspect}") ).send("#{type}_class") ]
      elsif params.is_a?(Array)
        params.collect { |stream| ( @@extensions[stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}") ).send("#{type}_class") }
      elsif params.is_a?(Hash)
        a = []
        params.each_pair { |stream, options| a << ( @@extensions[stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}") ).send("#{type}_class") }
        a
      else
        raise ArgumentError, "Invalid params supplied: #{params.inspect}"
      end
    end

    register_extension(:enc,  SymmetricEncryption::Reader, SymmetricEncryption::Writer)
    register_extension(:file, Streams::FileReader,         Streams::FileWriter)
    register_extension(:gz,   Streams::GzipReader,         Streams::GzipWriter)
    register_extension(:gzip, Streams::GzipReader,         Streams::GzipWriter)
    register_extension(:zip,  Streams::ZipReader,          Streams::ZipWriter)
  end
end