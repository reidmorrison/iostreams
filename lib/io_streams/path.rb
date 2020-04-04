module IOStreams
  class Path < IOStreams::Stream
    attr_accessor :path

    def initialize(path)
      raise(ArgumentError, "Path cannot be nil") if path.nil?
      raise(ArgumentError, "Path must be a string: #{path.inspect}, class: #{path.class}") unless path.is_a?(String)

      @path      = path.frozen? ? path : path.dup.freeze
      @io_stream = nil
      @builder   = nil
    end

    # If elements already contains the current path then it is used as is without
    # adding the current path for a second time
    def join(*elements)
      return self if elements.empty?

      elements = elements.collect(&:to_s)
      relative = ::File.join(*elements)

      new_path         = dup
      new_path.builder = nil
      new_path.path    = relative.start_with?(path) ? relative : ::File.join(path, relative)
      new_path
    end

    def relative?
      !absolute?
    end

    def absolute?
      !!(path.strip =~ %r{\A/})
    end

    # By default realpath just returns self.
    def realpath
      self
    end

    # Runs the pattern from the current path, returning the complete path for located files.
    #
    # See IOStreams::Paths::File.each for arguments.
    def each_child(pattern = "*", **args, &block)
      raise NotImplementedError
    end

    # Returns [Array] of child files based on the supplied pattern
    def children(*args, **kargs)
      paths = []
      each_child(*args, **kargs) { |path| paths << path }
      paths
    end

    # Returns [String] the current path.
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

    # Cleanup an incomplete write to the target "file" if the copy fails.
    def copy_from(source, **args)
      super(source, **args)
    rescue StandardError => e
      begin
        delete
      rescue NotImplementedError
      end
      raise(e)
    end

    # Moves the file by copying it to the new path and then deleting the current path.
    # Returns [IOStreams::Path] the target path.
    #
    # Notes:
    # - Currently only supports moving individual files, not directories.
    def move_to(target_path)
      target = IOStreams.new(target_path)
      target.mkpath
      target.copy_from(self, convert: false)
      delete
      target
    end

    # Returns [IOStreams::Path] the directory for this file.
    #
    # If `path` does not include a directory name then "." is returned.
    #
    #   IOStreams.path("test.rb").directory         #=> "."
    #   IOStreams.path("a/b/d/test.rb").directory   #=> "a/b/d"
    #   IOStreams.path(".a/b/d/test.rb").directory  #=> ".a/b/d"
    #   IOStreams.path("foo.").directory            #=> "."
    #   IOStreams.path("test").directory            #=> "."
    #   IOStreams.path(".profile").directory        #=> "."
    def directory
      new_path         = dup
      new_path.builder = nil
      new_path.path    = ::File.dirname(path)
      new_path
    end

    # When path is a file, deletes this file.
    # When path is a directory, attempts to delete this directory. If the directory contains
    # any children it will fail.
    #
    # Returns self
    #
    # Notes:
    # * No error is raised if the file or directory is not present.
    # * Only the file is removed, not any of the parent paths.
    def delete
      raise NotImplementedError
    end

    # When path is a directory ,deletes this directory and all its children.
    # When path is a file ,deletes this file.
    #
    # Returns self
    #
    # Notes:
    # * No error is raised if the file is not present.
    # * Only the file is removed, not any of the parent paths.
    # * All children paths and files will be removed.
    def delete_all
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

    # Returns [true|false] whether partially created files are visible on this path.
    #
    # With local file systems a file that is still being written to is visbile.
    # On AWS S3 a file is not visible until it is completely written to the bucket.
    def partial_files_visible?
      true
    end

    # TODO: Other possible methods:
    # - rename - File.rename
    # - rmtree - delete everything under this path - FileUtils.rm_r
    # - directory?
    # - file?
    # - empty?
    # - find(ignore_error: true) - Find.find

    # Paths are sortable by name
    def <=>(other)
      path <=> other.path
    end

    # Compare by path name, ignore streams
    def ==(other)
      path == other.path
    end

    def inspect
      str = "#<#{self.class.name}:#{path}"
      str << " @builder=#{builder.streams.inspect}" if builder.streams
      str << " @options=#{builder.options.inspect}" if builder.options
      str << " pipeline=#{pipeline.inspect}>"
    end

    private

    def builder
      @builder ||= IOStreams::Builder.new(path)
    end
  end
end
