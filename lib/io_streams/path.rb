# frozen_string_literal: true

require "pathname"

module IOStreams
  class Path < IOStreams::Stream
    attr_reader :path

    # The operations that each storage implements, when it supports them. See `#respond_to?`.
    OPERATIONS = %i[each_child mkpath mkdir exist? size mtime file? directory? empty? delete delete_all].freeze

    # The operations that are built on one of the OPERATIONS, which a path only supports when it supports that one.
    DERIVED_OPERATIONS = {children: :each_child, size?: :size, move_to: :delete}.freeze

    def initialize(path)
      raise(ArgumentError, "Path cannot be nil") if path.nil?
      raise(ArgumentError, "Path must be a string: #{path.inspect}, class: #{path.class}") unless path.is_a?(String)

      @path      = path.frozen? ? path : path.dup.freeze
      @io_stream = nil
      clear_configuration
    end

    # Returns [IOStreams::Path] a new path with the elements joined to this path.
    # Without any elements it returns a copy of this path, keeping its streams and options.
    #
    # If elements already contains the current path then it is used as is without
    # adding the current path for a second time
    def join(*elements)
      return dup if elements.empty?

      new_path = dup
      new_path.clear_configuration
      new_path.path = joined_path(::File.join(*elements.collect(&:to_s)))
      new_path
    end

    # Returns [IOStreams::Path] a new path with the element joined to this path, see #join.
    #
    # Like #join, and unlike `Pathname#/`, an absolute element is joined to this path rather than replacing it:
    #   IOStreams.path("/data") / "/b.csv"   # => /data/b.csv
    #
    # A name from untrusted input can still leave this path with `..`, such as `"../etc/passwd"`, and an absolute
    # element joined to an empty path, the current directory, is used as it is, so restrict the paths that can be
    # accessed with `IOStreams.add_allowed_path`.
    def /(other)
      join(other)
    end

    # Returns [IOStreams::Path] a copy of this path with `.`, `..` and repeated `/` removed, without accessing
    # the file, like `Pathname#cleanpath`. The copy keeps the streams and options, since it is the same file.
    #
    # Note: S3 treats `.` and `..` in a key as ordinary characters, but they are resolved here like any other path.
    def cleanpath
      clean      = dup
      clean.path = clean_name(path)
      clean
    end

    # Returns [IOStreams::Path] a new path with the last extension of the file name replaced, like `Pathname#sub_ext`.
    # The streams and options are cleared, since a new extension can mean other streams or another format.
    #   IOStreams.path("data.csv.gz").sub_ext(".bz2")   # => data.csv.bz2
    #   IOStreams.path("data.csv").sub_ext("")          # => data
    def sub_ext(extension)
      new_path = dup
      new_path.clear_configuration
      new_path.path = path.delete_suffix(::File.extname(path)) + extension.to_s
      new_path
    end

    # Returns [String] the name of this path relative to the supplied base path, like `Pathname#relative_path_from`,
    # without accessing either of them. Like #basename, the name has no storage of its own, so it is a String that
    # can be joined to another path, for example to copy every file within a directory to another store:
    #
    #   source = IOStreams.path("s3://bucket/exports")
    #   source.each_child("**/*") { |child| IOStreams.path("/backup").join(child.relative_path_from(source)).copy_from(child) }
    #
    # Parameters:
    #   base [IOStreams::Path|String]
    #
    # Raises ArgumentError when the base is in another store, such as another S3 bucket or SFTP host,
    # or when one path is absolute and the other is relative.
    def relative_path_from(base)
      base = IOStreams.path(base) unless base.is_a?(Path)
      raise(ArgumentError, "#{base.display_name} is not in the same store as #{display_name}") unless same_store?(base)

      # The names are compared by their bytes when either is not valid in its encoding, see IOStreams::Utils.matchable.
      names = [path.empty? ? "." : path, base.path.empty? ? "." : base.path]
      names = names.map(&:b) unless names.all?(&:valid_encoding?)
      Pathname.new(names.first).relative_path_from(Pathname.new(names.last)).to_s.force_encoding(path.encoding)
    end

    def relative?
      !absolute?
    end

    def absolute?
      path.start_with?("/")
    end

    # By default realpath just returns self.
    def realpath
      self
    end

    # Runs the pattern from the current path, returning the complete path for located files.
    #
    # See IOStreams::Paths::File.each for arguments.
    def each_child(*, **)
      raise_not_implemented(__method__)
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
      raise_not_implemented(__method__)
    end

    # Assumes the current path does not include a file name, and creates all elements in the path.
    # Returns self
    #
    # Note: Do not call this method if the path contains a file name, see `#mkpath`
    def mkdir
      raise_not_implemented(__method__)
    end

    # Returns [true|false] whether the file exists
    def exist?
      raise_not_implemented(__method__)
    end

    # Returns [Integer] the size of the file, like `File.size`.
    #
    # Raises [IOStreams::Errors::NotFound] when the file does not exist, see `#size?`.
    def size
      raise_not_implemented(__method__)
    end

    # Returns [Time] when the file was last modified, like `File.mtime`.
    #
    # Raises [IOStreams::Errors::NotFound] when the file does not exist.
    def mtime
      raise_not_implemented(__method__)
    end

    # Returns [Integer] the size of the file, or nil when it does not exist or is empty, like `File.size?`.
    def size?
      size = self.size
      size if size&.positive?
    rescue Errors::NotFound
      nil
    end

    # Returns [true|false] whether this path is a file that exists.
    def file?
      raise_not_implemented(__method__)
    end

    # Returns [true|false] whether this path is a directory that exists.
    def directory?
      raise_not_implemented(__method__)
    end

    # Returns [true|false] whether this path is a directory without any children, or a file without any data.
    # Returns false when it does not exist.
    def empty?
      raise_not_implemented(__method__)
    end

    # Returns [true|false] whether this path has an empty name, see `#to_s`.
    #
    # Defined explicitly so that ActiveSupport's `Object#blank?` (and therefore `present?`,
    # `presence`, and ActiveModel's `validates_presence_of` / `allow_blank:`) does not fall back
    # to `#empty?`. `#empty?` means "the file has no content" and may perform I/O, whereas
    # `blank?` should only mean "no path was supplied".
    def blank?
      to_s.empty?
    end

    # Moves the file by copying it to the new path and then deleting the current path.
    # Returns [IOStreams::Path] the target path.
    #
    # Raises ArgumentError when the target is the same location as this path, see #same_location?, since the file
    # would be deleted once it was copied onto itself.
    #
    # Notes:
    # - Currently only supports moving individual files, not directories.
    def move_to(target_path)
      target = to_stream(target_path)
      reject_move_onto_itself!(target)
      # Through a copy of the target, so that the directories that #mkpath creates when a file is next written, as on
      # SFTP, are not a lasting change to the target supplied.
      target.dup.mkpath.copy_from(self, convert: false)
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
      new_path = dup
      new_path.clear_configuration
      new_path.path = ::File.dirname(path)
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
      raise_not_implemented(__method__)
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
      raise_not_implemented(__method__)
    end

    # Returns [true|false] whether this path supports the method, like `Object#respond_to?`.
    #
    # An operation that a storage does not support, such as `#each_child` on an HTTP path, raises
    # NotImplementedError, and `respond_to?` returns false for it, as Ruby does for a method that is not
    # implemented on the platform, such as `Process.fork` on Windows. So does an operation built on it, such as
    # `#children`, see DERIVED_OPERATIONS.
    def respond_to?(name, include_all = false) # rubocop:disable Style/OptionalBooleanParameter -- the signature of Object#respond_to?
      operation = DERIVED_OPERATIONS.fetch(name.to_sym, name.to_sym)
      return false if OPERATIONS.include?(operation) && method(operation).owner == IOStreams::Path

      super
    end

    # Returns [true|false] whether this path can be accessed: whether it is within the allowed paths,
    # see `IOStreams.add_allowed_path`.
    #
    # Always true when no allowed paths have been added.
    #
    # Example:
    #   IOStreams.add_allowed_path("/var/data/uploads")
    #
    #   IOStreams.path("/var/data/uploads/file.csv").allowed?
    #   # => true
    #
    #   IOStreams.path("/etc/passwd").allowed?
    #   # => false
    def allowed?
      authorize!
      true
    rescue Errors::AccessDenied
      false
    end

    # Returns [true|false] whether partially created files are visible on this path.
    #
    # With local file systems a file that is still being written to is visbile.
    # On AWS S3 a file is not visible until it is completely written to the bucket.
    def partial_files_visible?
      true
    end

    # Paths sort by their full name in the spelling that #== compares, see #identity, so that equal paths compare
    # as 0, and then by the name of their class, so that paths of different classes never do.
    # Returns [nil] when compared with anything other than a path.
    def <=>(other)
      sort_key <=> other.sort_key if other.is_a?(Path)
    end

    # Returns [true|false] whether the other is a path of the same class that names the same file, whatever the
    # spelling of its name, see #identity, such as the case of the host of an SFTP or HTTP url, so that paths in
    # different locations are never equal. The streams and options are ignored, as are the arguments of the path that
    # do not identify the file, such as a password.
    #
    # Like `Pathname#==`, `.` and `..` are not resolved, and a path is never equal to a String, even its name, since only
    # a path knows which parts of its name identify it. Compare #to_s to compare the names as they are written.
    #   IOStreams.path("sftp://Example.org:22/a.csv") == IOStreams.path("sftp://example.org/a.csv")   # => true
    #   IOStreams.path("a.txt") == IOStreams.path("/home/user/a.txt")                               # => false
    def ==(other)
      other.instance_of?(self.class) && other.identity == identity
    end

    # Paths are equal hash keys when they are equal, see #==.
    alias eql? ==

    def hash
      [self.class, identity].hash
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

    # Does not create the builder, so that a frozen path can be inspected, for example in a `FrozenError` message.
    # The builder and the tabular settings each display their own fields, see `IOStreams::Builder#inspect_fields` and
    # `IOStreams::Tabular::Settings#inspect_fields`, without the values of sensitive options, such as a passphrase.
    def inspect
      builder = @builder || IOStreams::Builder.new(path)
      "#<#{self.class.name}:#{display_name}#{builder.inspect_fields}#{@tabular_settings&.inspect_fields}" \
        "#{builder.inspect_pipeline}>"
    end

    # Returns [String] the full name of this path, see #to_s, without any credentials, so that it can be logged
    # or displayed. A user name, password or query in an SFTP or HTTP url is removed, since it can hold
    # credentials, so unlike #to_s it cannot be used to create the path again.
    #
    # The name is valid UTF-8: each byte of a name that is not valid UTF-8, such as one written in Latin-1, is shown
    # as `\xHH`, see `IOStreams::Utils.display_text`.
    #
    # Example:
    #   IOStreams.path("sftp://jack:secret@example.org/data/a.csv").display_name
    #   # => "sftp://example.org/data/a.csv"
    def display_name
      Utils.display_text(to_s)
    end

    protected

    # Sets the path of a new path, for example in `#join` or `#directory`, which change a copy of this path.
    # Not public, since a path is a hash key, see #hash, and must not change once it has been returned.
    attr_writer :path

    # Returns [String] the name with `.`, `..` and repeated `/` removed, like `Pathname#cleanpath`, see #cleanpath,
    # keeping a trailing `/` when it names another file, see #trailing_slash_significant?. A path class whose names
    # differ in other ways, such as an SFTP name within the login directory, refines it.
    def clean_name(name)
      clean = Pathname.new(Utils.matchable(name)).cleanpath.to_s.force_encoding(name.encoding)
      return clean unless trailing_slash_significant? && name.end_with?("/") && !clean.end_with?("/")

      "#{clean}/"
    end

    # Returns [true|false] whether a name that ends with `/` names another file than the same name without it, so
    # that #clean_name keeps it, such as the key of an S3 folder object, or a url. False for a local or SFTP path,
    # which names the same directory with or without it.
    def trailing_slash_significant?
      false
    end

    # Returns [String] the path of the supplied name joined to this path, see #join: the name itself when it is
    # already within this path.
    def joined_path(name)
      contains?(name) ? name : ::File.join(path, name)
    end

    # Returns [String] the name that identifies the file of this path, including its store, which #==, #eql?, #hash and
    # #<=> compare: its full name, see #to_s, as it is written, as `Pathname#==` compares names. A path class whose
    # names can spell the same file in other ways, such as a url whose host can be written in any case, returns its name
    # in one spelling, without the parts of its name that do not identify the file, such as a password.
    #
    # It never makes a request of the store, and never resolves `.` or `..`, see #same_location?.
    def identity
      to_s
    end

    # Returns [Array(String, String)] what a path sorts by, see #<=>: its #identity, then the name of its class.
    # Defined only here, rather than by each path class, so that a path can ask a path of any other class for it: Ruby
    # only lets a path of the class that defines a protected method, such as `IOStreams::Paths::SFTP#identity`, call it.
    def sort_key
      [identity, self.class.to_s]
    end

    # Returns [true|false] whether the other path is the same location as this one, such as the same file, see
    # #move_to. Equal paths are, see #==, and each path class also detects the other names of a location that it can
    # tell without a request, such as a name with `.` or `..`.
    def same_location?(other)
      self == other
    end

    # Returns [true|false] whether the other path is in the same store as this one, so that their names can be
    # compared, see #relative_path_from.
    def same_store?(other)
      other.instance_of?(self.class) && other.store == store
    end

    # Returns the identity of the store that this path is in, such as the bucket of an S3 path, or the host and
    # port of an SFTP path. Every local file is in the same store.
    def store = nil

    # Raises NotImplementedError for an operation that this storage does not support.
    def raise_not_implemented(operation)
      raise(NotImplementedError, "#{self.class.name} does not support ##{operation}: #{display_name}")
    end

    # Raises [IOStreams::Errors::AccessDenied] when allowed paths have been added, see `IOStreams.add_allowed_path`,
    # and this path is not within any of them.
    def authorize!
      return if IOStreams.allowed_paths.empty? || (@permitted_path && @permitted_path == path)

      authorize_location!(allowed_location)
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

    # Returns [Module] the kind of failure, such as `IOStreams::Errors::NotFound`, that an exception raised by the
    # storage of this path means, or nil when it is none of them, see `IOStreams::Errors::StorageError`.
    #
    # Each path class returns the kinds of failure of its own storage, and makes each request of its storage within
    # `#tag_failure`. A path class registered with `IOStreams.register_scheme` can do the same.
    def failure_kind(_exception)
      nil
    end

    # Calls the block, which makes a request of the storage of this path, and tags an exception that it raises with
    # the kind of failure that it means, see `#failure_kind`, and the display name of the supplied path. That is this
    # path, unless the failure is known to be another path's, such as the source of a copy.
    #
    # Only make the request within the block, never call a block that the caller supplied, since an exception raised
    # by the caller's block, such as `Errno::ENOENT` for another file, is not a failure of this path.
    def tag_failure(path = self)
      yield
    rescue StandardError => e
      kind = failure_kind(e)
      raise unless kind

      raise(kind.tag(e, path.display_name))
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
      # A name that is not valid in its encoding is split by its bytes, see Utils.matchable.
      Utils.matchable(name).split("/").each do |segment|
        case segment
        when "", "."
          next
        when ".."
          segments.pop
        else
          segments << segment
        end
      end
      "/#{segments.join('/')}".force_encoding(name.encoding)
    end

    # Raises ArgumentError when the target is the same location as this path, see #same_location?.
    def reject_move_onto_itself!(target)
      return unless same_location?(target)

      raise(ArgumentError, "Cannot move #{display_name} onto itself, as #{target.display_name}: it would delete the file")
    end

    # Reads this file through a temp file, for a store that can only download a whole file: calls `download` with the
    # name of the temp file, which only the current user can read, then reads it through the streams of this path,
    # yielding to the block as #reader does. The temp file is deleted once the block returns.
    def spooled_reader(prefix, download:, &block)
      Utils.private_temp_file(prefix, purpose: "the download of #{display_name}") do |file_name|
        download.call(file_name)
        ::File.open(file_name, "rb") { |io| builder.reader(io, display_name: display_name, &block) }
      end
    end

    # Writes this file through a temp file, for a store that can only upload a whole file: writes what the block writes
    # into the temp file through the streams of this path, as #writer does, then calls `upload` with its name once the
    # block returns, including when it leaves early, such as with `break`, as a local file keeps what was written, but
    # not when it raises, or its thread is killed, see `IOStreams::Utils.finish_or_abort`.
    def spooled_writer(prefix, upload:, &block)
      Utils.private_temp_file(prefix, purpose: "the upload to #{display_name}") do |file_name|
        Utils.finish_or_abort(finish: -> { upload.call(file_name) }) do
          ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }
        end
      end
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
