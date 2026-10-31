require "fileutils"

module IOStreams
  module Paths
    class File < IOStreams::Path
      # A pattern supplied to #each_child that is not a String, such as a Pathname, is deprecated.
      PATTERN_DEPRECATION = "a pattern that is not a String is deprecated for #each_child and #children, since v3.0 " \
                            "raises ArgumentError for it, supply a String instead, such as pattern.to_s".freeze
      private_constant :PATTERN_DEPRECATION

      # Moving a file onto an existing directory is deprecated, see #move_to.
      MOVE_DEPRECATION = "#move_to onto an existing directory is deprecated, since v3.0 raises ArgumentError for it, " \
                         "supply the file within the directory instead, such as " \
                         "move_to(IOStreams.path(directory).join(path.basename))".freeze
      private_constant :MOVE_DEPRECATION

      attr_reader :create_path

      def initialize(file_name, create_path: true)
        @create_path = create_path
        super(file_name)
      end

      # Sets whether writing the file creates its directory first, see #mkpath.
      def create_path=(create_path)
        warn_change("#create_path=")
        @create_path = create_path
      end

      # Returns [String|nil] the deprecation warning for a name that IOStreams v3.0 reads as another file, see
      # `IOStreams::Path.name_deprecation`, or nil for one that it reads the same way:
      # - A name of `~`, or starting with `~/`, which is within a directory called `~` in the current directory, while
      #   v3.0 reads it within the home directory. A name such as `~user/a.csv` or `~$Book1.xlsx` is the same on both.
      # - A `file://` url, such as `file:///data/a.csv` or `file://~/a.csv`, which is a file name relative to the current
      #   directory, within a directory called `file:`, while v3.0 reads it as the local file that it names, such as
      #   `/data/a.csv`, or within the home directory.
      def self.name_deprecation(name)
        if file_url?(name)
          "a file:// url is deprecated, since v3.0 reads it as the local file that it names, such as /data/a.csv for " \
            "file:///data/a.csv, or a file within the home directory for file://~/a.csv, rather than as a file name " \
            "relative to the current directory: supply the name of the file instead, such as /data/a.csv, or " \
            "File.expand_path(\"~/a.csv\") for the home directory"
        elsif name == "~" || name.start_with?("~/")
          "a local file name of ~, or starting with ~/, is deprecated, since v3.0 reads it within the home directory, " \
            "rather than within a directory called ~ in the current directory: expand it with File.expand_path for " \
            "the home directory, or start it with ./~/ for the directory called ~"
        end
      end

      # Returns [String|nil] the deprecation warning for a name that IOStreams v3.0 reads as another file, see
      # .name_deprecation, which is in another directory, and so another allowed path.
      def self.location_deprecation(name)
        name_deprecation(name)
      end

      # Returns [true|false] whether the name is a `file://` url, in any case, as IOStreams v3.0 takes it, see
      # .name_deprecation. Its first bytes are compared, so that a name that is not valid in its encoding, such as a
      # Latin-1 name, can be checked too.
      def self.file_url?(name)
        name.include?("://") && name.byteslice(0, 7).b.casecmp?("file://")
      end
      private_class_method :file_url?

      # Yields Paths within the current path.
      #
      # Examples:
      #
      # # Case Insensitive file name lookup:
      # IOStreams.path("ruby").each_child("r*.md") { |path| puts path }
      #
      # # Case Sensitive file name lookup:
      # IOStreams.path("ruby").each_child("R*.md", case_sensitive: true) { |path| puts path }
      #
      # # Also return the names of directories found during the search:
      # IOStreams.path("ruby").each_child("R*.md", directories: true) { |path| puts path }
      #
      # # Case Insensitive recursive file name lookup:
      # IOStreams.path("ruby").each_child("**/*.md") { |path| puts path }
      #
      # Parameters:
      #   pattern [String]
      #     The pattern is not a regexp, it is a string that may contain the following metacharacters:
      #     `*`      Matches all regular files.
      #     `c*`     Matches all regular files beginning with `c`.
      #     `*c`     Matches all regular files ending with `c`.
      #     `*c*`    Matches all regular files that have `c` in them.
      #
      #     `**`     Matches recursively into subdirectories.
      #
      #     `?`      Matches any one character.
      #
      #     `[set]`  Matches any one character in the supplied `set`.
      #     `[^set]` Does not matches any one character in the supplied `set`.
      #
      #     `\`      Escapes the next metacharacter.
      #
      #     `{a,b}`  Matches on either pattern `a` or pattern `b`.
      #
      #   case_sensitive [true|false]
      #     Whether the pattern is case-sensitive.
      #
      #   directories [true|false]
      #     Whether to yield directory names.
      #
      #   hidden [true|false]
      #     Whether to yield hidden paths.
      #
      # Examples:
      #
      # Pattern:    File name:       match?   Reason                        Options
      # =========== ================ ======   ============================= ===========================
      # "cat"       "cat"            true     # Match entire string
      # "cat"       "category"       false    # Only match partial string
      #
      # "c{at,ub}s" "cats"           true     # { } is supported
      #
      # "c?t"       "cat"            true     # "?" match only 1 character
      # "c??t"      "cat"            false    # ditto
      # "c*"        "cats"           true     # "*" match 0 or more characters
      # "c*t"       "c/a/b/t"        true     # ditto
      # "ca[a-z]"   "cat"            true     # inclusive bracket expression
      # "ca[^t]"    "cat"            false    # exclusive bracket expression ("^" or "!")
      #
      # "cat"       "CAT"            false    # case sensitive              {case_sensitive: false}
      # "cat"       "CAT"            true     # case insensitive
      #
      # "\?"        "?"              true     # escaped wildcard becomes ordinary
      # "\a"        "a"              true     # escaped ordinary remains ordinary
      # "[\?]"      "?"              true     # can escape inside bracket expression
      #
      # "*"         ".profile"       false    # wildcard doesn't match leading period by default
      # "*"         ".profile"       true     # unless hidden is enabled    {hidden: true}
      # ".*"        ".profile"       true     # leading period is explicit
      #
      # "**/*.rb"   "main.rb"        false
      # "**/*.rb"   "./main.rb"      false
      # "**/*.rb"   "lib/song.rb"    true
      # "**.rb"     "main.rb"        true
      # "**.rb"     "./main.rb"      false
      # "**.rb"     "lib/song.rb"    true
      # "*"         "dave/.profile"  true
      #
      # A pattern that is not a String, such as a Pathname, is deprecated, and reports a deprecation warning, see
      # `IOStreams::Deprecation`.
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        Deprecation.warn(PATTERN_DEPRECATION) unless pattern.is_a?(String)
        authorize!

        # A pattern that is a Pathname is taken by its #to_path, as `::File.join` takes it, which v2.1 joined the pattern
        # with: `IOStreams::Utils::PathName.join` does not take it on JRuby, where it joins the names by their bytes, and
        # the case-insensitive retry below matches and downcases the pattern as a String.
        pattern = pattern.to_path if pattern.respond_to?(:to_path)

        flags = 0
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden

        full_pattern = Utils::PathName.join(path, pattern)

        results = Dir.glob(full_pattern, flags)

        # On some platforms or Ruby versions, FNM_CASEFOLD may not work properly
        # with complex patterns. If case-insensitive matching returns no results
        # but we expected some, try a more robust approach.
        if results.empty? && !case_sensitive && pattern.match?(/[A-Z]/)
          # Try converting the pattern to lowercase and re-matching
          lowercase_pattern = pattern.downcase
          lowercase_full_pattern = Utils::PathName.join(path, lowercase_pattern)
          results = Dir.glob(lowercase_full_pattern, flags)
        end

        results.each do |full_path|
          next if !directories && ::File.directory?(full_path)

          child = self.class.new(full_path)
          yield(child) if allowed_child?(child)
        end
      end

      # Moves this file to the `target_path` by copying it to the new name and then deleting the current file.
      #
      # Notes:
      # - Can copy across buckets.
      # - A target that is an existing directory, which the file is moved into, as `mv` does, returning the directory, is
      #   deprecated, and reports a deprecation warning, see `IOStreams::Deprecation`: supply the file within it instead,
      #   such as `move_to(IOStreams.path("/archive").join(path.basename))`.
      def move_to(target_path)
        target = IOStreams.new(target_path)
        return super(target) unless target.is_a?(self.class)

        authorize!
        target.authorize!
        Deprecation.warn(MOVE_DEPRECATION) if ::File.directory?(target.path)
        target.mkpath
        # In case the file is being moved across partitions
        FileUtils.move(path, target.to_s)
        target
      end

      def mkpath
        authorize!
        dir = Utils::PathName.dirname(path)
        FileUtils.mkdir_p(dir)
        self
      end

      def mkdir
        authorize!
        FileUtils.mkdir_p(path)
        self
      end

      def exist?
        authorize!
        ::File.exist?(path)
      end

      def size
        authorize!
        ::File.size(path)
      end

      def delete
        authorize!
        return self unless exist?

        ::File.directory?(path) ? Dir.delete(path) : ::File.unlink(path)
        self
      end

      def delete_all
        authorize!
        return self unless exist?

        ::File.directory?(path) ? FileUtils.remove_dir(path) : ::File.unlink(path)
        self
      end

      # Returns the real path by stripping `.`, `..` and expands any symlinks.
      def realpath
        authorize!
        self.class.new(::File.realpath(path))
      end

      private

      # Returns [String] the real path of this file, following any symbolic links, which is compared
      # against the allowed paths.
      #
      # The part of the path that does not exist yet, for example a file that is about to be written,
      # is appended to the real path of the part that does exist. It cannot contain `.` or `..`, since
      # what they refer to depends on directories that have not been created yet.
      def allowed_location
        existing = ::File.absolute_path?(path) ? path : Utils::PathName.join(Dir.pwd, path)
        missing  = []
        until present?(existing)
          parent = Utils::PathName.dirname(existing)
          break if parent == existing

          missing.unshift(Utils::PathName.basename(existing))
          existing = parent
        end

        if missing.intersect?([".", ".."])
          raise(Errors::AccessDenied, "Access denied to #{path}: '.' and '..' are not allowed after a missing directory")
        end

        Utils::PathName.join(::File.realpath(existing), *missing)
      rescue SystemCallError => e
        raise(Errors::AccessDenied, "Access denied to #{path}: #{e.message}")
      end

      # Returns [true|false] whether the file, directory or symbolic link exists, without following the link.
      def present?(file_name)
        ::File.lstat(file_name)
        true
      rescue SystemCallError
        false
      end

      # Read from file
      def stream_reader(&block)
        ::File.open(path, "rb") { |io| builder.reader(io, &block) }
      end

      # Write to file
      #
      # Note:
      #   If an exception is raised whilst the file is being written to the file is removed to
      #   prevent incomplete / partial files from being created.
      def stream_writer(&block)
        mkpath if create_path
        begin
          ::File.open(path, "wb") { |io| builder.writer(io, &block) }
        rescue StandardError => e
          ::FileUtils.rm_f(path)
          raise(e)
        end
      end
    end
  end
end
