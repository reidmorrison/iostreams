module RocketJob
  module Streams
    autoload :Encryption, 'rocket_job/streams/encryption'
    autoload :File,       'rocket_job/streams/file'
    autoload :Gzip,       'rocket_job/streams/gzip'
    autoload :Zip,        'rocket_job/streams/zip'

    # A registry to hold formats for processing files during upload or download
    @@extensions = ThreadSafe::Hash.new

    # Returns [Array] the formats required to process the file by looking at
    # its extension(s)
    #
    # Extensions supported:
    #   .zip       Zip File                                   [ :zip ]
    #   .gz, .gzip GZip File                                  [ :gzip ]
    #   .enc       File Encrypted using symmetric encryption  [ :encrypted ]
    #   other      All other extensions will be returned as:  [ :plain ]
    #
    # When a file is encrypted, it may also be compressed:
    #   .zip.enc  [ :zip, :encrypted ]
    #   .gz.enc   [ :gz,  :encrypted ]
    #
    # Example:
    #   RocketJob::Formatter::Formats.streamss_for('myfile.zip'
    def streams_for_file_name(file_name)
      raise ArgumentError.new("RocketJob Cannot detect file format when uploading a stream") unless file_name.is_a?(String)
      if extension = File.extname(file_name).downcase[1..-1]
        if klass = @@extensions[extension.to_sym]
          parent_format = streams_for_file_name(extension)
          if parent_format
            parent_format + klass.new
          else
            [ klass.new ]
          end
        end
      end
    end

    # Returns [Array] stream hash for the supplied stream parameter list
    def streams_for(params)
      if params.is_a?(Symbol)
        [ ( @@extensions[params] || raise(ArgumentError, "Unknown Stream type: #{params.inspect}") ).new ]
      elsif params.is_a?(Array)
        h.collect { |stream| ( @@extensions[stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}") ).new }
      elsif params.is_a?(Hash)
        a = {}
        params.each_pair { |stream, options| a << ( @@extensions[stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}") ).new(options || {}) }
        a
      else
        raise ArgumentError, "Invalid params supplied: #{params.inspect}"
      end
    end

    # Register a file extension and the class to use to format it
    def register_stream(extension, stream_klass)
      extension = extension.to_s
      raise "Invalid extension #{extension.inspect}" unless extension =~ /\A\w+\Z/
      @@extensions[extension.to_sym] = stream_klass
    end

    # Read from a file or stream, decrypting the contents as it is read
    def read(file_name_or_io, streams=nil, &block)
      streams = if streams
        streams_for(streams)
      else
        raise ArgumentError.new("RocketJob Cannot detect the format when uploading a stream") unless file_name_or_io.is_a?(String)
        streams_for_file_name(file_name_or_io)
      end

# TODO Chain together the multiple streams
      last = streams.shift
      streams.each do |stream|
        last = last.read(file_name_or_io) do |io|
          
        end
      end
    end


    ##########################################################################
    private

    register_stream(:enc,  Streams::Encryption)
    register_stream(:file, Streams::File)
    register_stream(:gz,   Streams::Gzip)
    register_stream(:gzip, Streams::Gzip)
    register_stream(:zip,  Streams::Zip)
  end
end