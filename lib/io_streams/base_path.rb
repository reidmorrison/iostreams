# frozen_string_literal: true
module IOStreams
  class BasePath
    attr_reader :path

    def initialize(path)
      @path = path.frozen? ? path : path.dup.freeze
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

    # Return a reader for this path
    def reader(**args, &block)
      IOStreams.reader(path, **args, &block)
    end

    # Return a writer for this path
    def writer(**args, &block)
      IOStreams.writer(path, **args, &block)
    end

  end
end
