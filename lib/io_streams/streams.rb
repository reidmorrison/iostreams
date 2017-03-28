module IOStreams
  # Contains behavior for streams
  #
  # When a file is being read the streams are processed from right to left.
  # When writing a file streams are processed left to right.
  # For example:
  #   file.gz.enc ==> [:gz, :enc]
  #     Read:  Unencrypt, then Gunzip
  #     Write: GZip, then Encrypt
  class Streams

    # Returns [Streams] collection of streams to process against the file
    #
    def self.streams_for_file_name(file_name)

    end

    # Create a processing stream given:
    # - No stream. Defaults to :file
    # - A single String implies a file_name and the streams will be created based on the file_name
    # - One or more symbols or hashes for a stream
    # - One or more arrays for streams
    def initialize(*args)
      if args.size == 0
        @streams = [:file]
      elsif args.size == 1
        stream = args.first
        if stream
          @stream = stream.is_a?(String) ? streams_for_file_name(stream) : Array(stream)
        else
          @streams = [:file]
        end
      else
        @streams = streams
      end
      @streams.flatten!
    end

    def delimited?

    end

    def delete(stream)

    end

    # Add another stream for processing
    def <<(stream)

    end

    # Add a stream for processing
    def unshift(stream)

    end

    private

    # Return the Stream klass for the specified hash or symbol
    # Parameters
    #   stream [Hash|Symbol]
    def stream_for(stream)
      if stream.is_a?(Symbol)
        registered_klass(stream, {})
      else
        registered_klass(@stream.first)
      end
    end

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
    def streams_for_file_name(file_name)
      raise ArgumentError.new("RocketJob Cannot detect file format when uploading to stream: #{file_name.inspect}") if reader_stream?(file_name)

      parts      = file_name.split('.')
      extensions = []
      while extension = parts.pop
        break unless @@extensions[extension.to_sym]
        extensions.unshift(extension.to_sym)
      end
      extensions << :file if extensions.size == 0
      extensions
    end


  end
end
