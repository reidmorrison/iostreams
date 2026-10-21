module IOStreams
  class Path < IOStreams::Stream
    attr_reader :path

    def initialize(path)
      raise(ArgumentError, "Path cannot be nil") if path.nil?
      raise(ArgumentError, "Path must be a string: #{path.inspect}, class: #{path.class}") unless path.is_a?(String)

      @path      = path.frozen? ? path : path.dup.freeze
      @io_stream = nil
      @builder   = nil
    end

    # Returns [IOStreams::Path] a new path with the elements joined to this path, created with the same arguments as
    # this path, such as the credentials of an SFTP path, but without the streams, options, format and schema set on
    # this one. Without any elements it returns this path itself.
    #
    # If elements already contains the current path then it is used as is without
    # adding the current path for a second time
    def join(*elements)
      return self if elements.empty?

      elements = elements.collect(&:to_s)
      relative = ::File.join(*elements)

      new_path = dup
      new_path.reset_builder
      new_path.replace_path(contains?(relative) ? relative : ::File.join(path, relative))
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

    # Returns [IOStreams::Path] the directory for this file, a new path created with the same arguments as this path,
    # but without the streams, options, format and schema set on this one, see #join.
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
      new_path = dup
      new_path.reset_builder
      new_path.replace_path(::File.dirname(path))
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

    # Returns [Array<Symbol>] the options for creating a path of this class whose values must not be displayed,
    # such as a password, see .redact_options. A path class with sensitive options overrides it.
    def self.sensitive_option_names
      []
    end

    # Returns [Hash] the supplied options for creating a path of this class, such as `password:`, with the value of
    # each sensitive option replaced with "[FILTERED]", so that they can be displayed, for example by an application
    # that stores them to create the path later. See .sensitive_option_names and `IOStreams::Utils.redact_options`.
    def self.redact_options(options)
      Utils.redact_options(options, sensitive_option_names)
    end

    # Shows the full name of the path, see #display_name, without any credentials, and the options of its streams
    # without the values of sensitive options, such as a passphrase, see `IOStreams.redact_stream_options`.
    def inspect
      str = "#<#{self.class.name}:#{display_name}"
      str << " @builder=#{redact(builder.streams).inspect}" if builder.streams
      str << " @options=#{redact(builder.options).inspect}" if builder.options
      str << " pipeline=#{redact(pipeline).inspect}>"
    end

    # Returns [String] the full name of this path, see #to_s, without any credentials, so that it can be logged
    # or displayed. A user name, password or query in an SFTP or HTTP url is removed, since it can hold
    # credentials, so unlike #to_s it cannot be used to create the path again. Each byte of a name that is not
    # valid UTF-8 is shown as `\xHH`, see `IOStreams::Utils.display_text`.
    #
    # Example:
    #   IOStreams.path("sftp://jack:secret@example.org/data/a.csv").display_name
    #   # => "sftp://example.org/data/a.csv"
    def display_name
      Utils.display_text(to_s)
    end

    # Deprecated: a path can be used by many objects at once, such as a root path that file names are joined to, so
    # changing it in place changes it for all of them. Use #join or #directory, which return a new path, without the
    # streams, options, format and schema set on this one, or `IOStreams.path` with the new name. Reports a
    # deprecation warning, see `IOStreams::Deprecation`.
    def path=(path)
      Deprecation.warn("#path= is deprecated, use #join or #directory, which return a new path, or IOStreams.path " \
                       "with the new name")
      @path = path
    end

    protected

    # Returns [self] after setting its path in place, for IOStreams itself, see #path=.
    def replace_path(path)
      @path = path
      self
    end

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

      IOStreams.logger&.warn("Skipping #{child.display_name} since it is not within any of the allowed paths")
      false
    end

    # Allows this exact path regardless of the allowed paths, for paths created by IOStreams itself such as temp files.
    # Returns self
    def permit!
      @permitted_path = path
      self
    end

    # Returns [Hash<Symbol:Hash>] the streams with the values of sensitive options replaced.
    def redact(streams)
      IOStreams.redact_stream_options(streams)
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
