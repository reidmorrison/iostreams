module IOStreams
  class Streams
    attr_accessor :file_name
    attr_reader :streams, :options

    def initialize(file_name = nil)
      @file_name = file_name
      @streams   = nil
      @options   = nil
    end

    # Supply an option that is only applied once the file name extensions have been parsed.
    # Note:
    # - Cannot set both `stream` and `option`
    def option(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance}") if @streams
      raise(ArgumentError, "Cannot call #option unless the `file_name` was already set}") unless file_name

      @options ||= {}
      if opts = @options[stream]
        opts.merge!(options)
      else
        @options[stream] = options.dup
      end
      self
    end

    def stream(stream, **options)
      stream = stream.to_sym unless stream.is_a?(Symbol)
      raise(ArgumentError, "Cannot call both #option and #stream on the same streams instance}") if @options

      # To prevent any streams from being applied supply a stream named `:none`
      if stream == :none
        @streams = {}
        return self
      end
      raise(ArgumentError, "Invalid stream: #{stream.inspect}") unless IOStreams.extensions.include?(stream)

      @streams ||= {}
      if opts = @streams[stream]
        opts.merge!(options)
      else
        @streams[stream] = options.dup
      end
      self
    end

    def reader(io_stream, &block)
      streams = build_streams(:reader)
      execute(streams, io_stream, &block)
    end

    def writer(io_stream, &block)
      streams = build_streams(:writer)
      execute(streams, io_stream, &block)
    end

    private

    # Returns [Hash<klass, options>] the streams that will be processed.
    # Parameters
    #   type: [:reader|writer]
    def build_streams(type)
      built_streams = {}
      if streams
        streams.each_pair { |stream, opts| built_streams[class_for_stream(type, stream)] = opts }
      elsif file_name
        if options
          # Add encoding stream first if the option was supplied.
          if opts = options[:encoding]
            built_streams[class_for_stream(type, :encoding)] = opts
          end
          parse_extensions.each { |stream| built_streams[class_for_stream(type, stream)] = options[stream] || {} }
        else
          parse_extensions.each { |stream| built_streams[class_for_stream(type, stream)] = {} }
        end
      else
        raise(ArgumentError, "Either call #stream or #file_name in order to build the required streams")
      end
      built_streams
    end

    def class_for_stream(type, stream)
      ext = IOStreams.extensions[stream.nil? ? nil : stream.to_sym] || raise(ArgumentError, "Unknown Stream type: #{stream.inspect}")
      ext.send("#{type}_class")
    end

    # Returns the streams for the supplied file_name
    def parse_extensions
      parts      = ::File.basename(file_name).split('.')
      extensions = []
      while extension = parts.pop
        sym = extension.downcase.to_sym
        break unless IOStreams.extensions[sym]

        extensions.unshift(sym)
      end
      extensions
    end

    # Executes the streams that need to be executed.
    def execute(streams, io_stream, &block)
      raise(ArgumentError, 'IOStreams call is missing mandatory block') if block.nil?

      if streams.empty?
        block.call(io_stream)
      elsif streams.size == 1
        klass, opts = streams.first
        klass.stream(io_stream, opts, &block)
      else
        # Daisy chain multiple streams together
        last = streams.keys.inject(block) { |inner, klass| ->(io) { klass.stream(io, streams[klass], &inner) } }
        last.call(io_stream)
      end
    end
  end
end
