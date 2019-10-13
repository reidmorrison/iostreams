module IOStreams
  class Path < IOStreams::Stream
    attr_reader :path

    def initialize(path)
      raise(ArgumentError, 'Path cannot be nil') if path.nil?
      raise(ArgumentError, "Path must be a string: #{path.inspect}, class: #{path.class}") unless path.is_a?(String)

      @path      = path.frozen? ? path : path.dup.freeze
      @io_stream = nil
      @streams   = nil
    end

    # If elements already contains the current path then it is used as is without
    # adding the current path for a second time
    def join(*elements)
      return self if elements.empty?

      relative = ::File.join(*elements)
      if relative.start_with?(path)
        self.class.new(relative)
      else
        self.class.new(::File.join(path, relative))
      end
    end

    # Runs the pattern from the current path, returning the complete path for located files.
    #
    # See IOStreams::Paths::File.each for arguments.
    def each(pattern = "*", **args)
      self.class.each(File.join(path, pattern), **args)
    end

    def to_s
      path
    end

    # Removes the last element of the path, the file name, before creating the entire path.
    # Returns self
    def mkpath
      raise NotImplementedError
    end

    # Assumes the current path does not include a file name, and creates all elements in the path.
    # Returns self
    #
    # Note: Do not call this method if the path contains a file name, see `#mkpath`
    def mkdir
      raise NotImplementedError
    end

    # Returns [true|false] whether the file exists
    def exist?
      raise NotImplementedError
    end

    # Returns [Integer] size of the file
    def size
      raise NotImplementedError
    end

    # Delete the file.
    # Returns self
    #
    # Notes:
    # * No error is raised if the file is not present.
    # * Only the file is removed, not any of the parent paths.
    def delete
      raise NotImplementedError
    end

    # Returns [true|false] whether the file is compressed based on its file extensions.
    def compressed?
      # TODO: Look at streams?
      !(path =~ /\.(zip|gz|gzip|xls.|)\z/i).nil?
    end

    # Returns [true|false] whether the file is encrypted based on its file extensions.
    def encrypted?
      # TODO: Look at streams?
      !(path =~ /\.(enc|pgp|gpg)\z/i).nil?
    end

    # Extract URI scheme if any was supplied
    def scheme
      @scheme ||= URI.parse(path).scheme
    end

    # TODO: WIP:
    #
    # Example:
    #   source = IOStreams.path('abc/file.xls')
    #   target = IOStreams.path('abc/file.xls.enc')
    # def copy(target, source_options: {}, target_options: {}, buffer_size: 65536, &block)
    #   if target.is_a?(self.class)
    #     target_options = target_options.dup
    #     source_options = source_options.dup
    #
    #     target_options[:streams] ||= target.streams
    #     source_options[:streams] ||= streams
    #     IOStreams.copy(path, target.path, source_options: source_options, target_options: target_options, buffer_size: buffer_size, &block)
    #   else
    #     IOStreams.copy(path, target, source_options: source_options, target_options: target_options, buffer_size: buffer_size, &block)
    #   end
    # end

    private

    def streams
      @streams ||= IOStreams::Streams.new(path)
    end
  end
end
