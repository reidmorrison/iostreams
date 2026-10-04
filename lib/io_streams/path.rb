module IOStreams
  class Path < IOStreams::Stream
    # Stream option names whose values must not be displayed, such as `passphrase` or `signer_passphrase`.
    SENSITIVE_OPTION = /pass(phrase|word)|secret/i
    private_constant :SENSITIVE_OPTION

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
      new_path.path    = contains?(relative) ? relative : ::File.join(path, relative)
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
    def each_child(pattern = "*", **args, &)
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

    # See Stream#reader.
    #
    # Raises [IOStreams::Errors::AccessDenied] when this path is not within any of the allowed paths,
    # see `IOStreams.add_allowed_path`.
    def reader(...)
      authorize!
      super
    end

    # See Stream#writer.
    #
    # Raises [IOStreams::Errors::AccessDenied] when this path is not within any of the allowed paths,
    # see `IOStreams.add_allowed_path`.
    def writer(...)
      authorize!
      super
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

    # Removes an incomplete target "file" when the copy fails.
    #
    # Only a target that did not exist before the copy is removed, so that a failed copy never deletes
    # existing data, for example an S3 object that is only replaced once the upload completes.
    def copy_from(source, **args)
      existed = existed_before_copy?
      begin
        super
      rescue StandardError => e
        delete_incomplete_copy unless existed
        raise(e)
      end
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
      !(path =~ /\.(zip|gz|gzip|xlsx|xlsm|bz2)\z/i).nil?
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
      str << " @builder=#{redact(builder.streams).inspect}" if builder.streams
      str << " @options=#{redact(builder.options).inspect}" if builder.options
      str << " pipeline=#{redact(pipeline).inspect}>"
    end

    protected

    # Raises [IOStreams::Errors::AccessDenied] when allowed paths have been added, see `IOStreams.add_allowed_path`,
    # and this path is not within any of them.
    def authorize!
      return if IOStreams.allowed_paths.empty? || (@permitted_path && @permitted_path == path)

      authorize_location!(allowed_location)
    end

    # Returns [true|false] whether this path is within the allowed paths, see `#authorize!`.
    def allowed?
      authorize!
      true
    rescue Errors::AccessDenied
      false
    end

    private

    # Returns [String] the normalized location of this path, which is compared against the allowed paths.
    #
    # Each path class that can be used with allowed paths overrides this method. Without it every path
    # of that class is denied once allowed paths have been added.
    #
    # Raises [IOStreams::Errors::AccessDenied] when the location cannot be determined.
    def allowed_location
      raise(Errors::AccessDenied, "Access denied: #{self.class.name} does not support allowed paths")
    end

    # Raises [IOStreams::Errors::AccessDenied] when the supplied location, see `#allowed_location`,
    # is not within any of the allowed paths.
    def authorize_location!(location)
      return if IOStreams.allowed_paths.any? { |allowed_path| within?(location, allowed_path) }

      raise(Errors::AccessDenied, "Access denied to #{location}: it is not within any of the allowed paths")
    end

    # Returns [String] the supplied path with `.`, `..` and repeated `/` resolved, the way a remote server
    # resolves them, without accessing it. The path always starts with `/`, and `..` cannot go above it.
    def normalize_path(name)
      segments = []
      name.split("/").each do |segment|
        case segment
        when "", "."
          next
        when ".."
          segments.pop
        else
          segments << segment
        end
      end
      "/#{segments.join('/')}"
    end

    # Returns [true|false] whether a child found by `#each_child` is within the allowed paths, logging it when it is not.
    def allowed_child?(child)
      return true if child.allowed?

      IOStreams.logger&.warn("Skipping #{child} since it is not within any of the allowed paths")
      false
    end

    # Allows this exact path regardless of the allowed paths, for paths created by IOStreams itself such as temp files.
    # Returns self
    def permit!
      @permitted_path = path
      self
    end

    # Returns [true|false] whether this path exists, or true when that cannot be determined.
    def existed_before_copy?
      exist?
    rescue NotImplementedError
      true
    end

    # rubocop:disable-next Lint/SuppressedException
    def delete_incomplete_copy
      delete
    rescue NotImplementedError
    end

    # Returns [Hash<Symbol:Hash>] the streams with the values of sensitive options replaced.
    def redact(streams)
      streams.transform_values do |options|
        next options unless options.is_a?(Hash)

        options.to_h { |name, value| [name, name.to_s.match?(SENSITIVE_OPTION) ? "[FILTERED]" : value] }
      end
    end

    def builder
      @builder ||= IOStreams::Builder.new(path)
    end

    # Returns [true|false] whether the supplied path is this path, or is within this path.
    # For example "a/b" contains "a/b/c.csv", but not "a/bc.csv".
    def contains?(other)
      path.empty? || within?(other, path)
    end

    # Returns [true|false] whether the path `child` is `parent`, or is within `parent`.
    def within?(child, parent)
      child == parent || child.start_with?(parent.end_with?("/") ? parent : "#{parent}/")
    end
  end
end
