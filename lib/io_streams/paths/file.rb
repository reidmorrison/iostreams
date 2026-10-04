require "fileutils"

module IOStreams
  module Paths
    class File < IOStreams::Path
      attr_accessor :create_path

      def initialize(file_name, create_path: true)
        @create_path = create_path
        super(file_name)
      end

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
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        unless block_given?
          return to_enum(__method__, pattern,
                         case_sensitive: case_sensitive, directories: directories, hidden: hidden)
        end

        authorize!

        flags = 0
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden

        # Dir.each_child("testdir") {|x| puts "Got #{x}" }
        full_pattern = ::File.join(path, pattern)

        results = Dir.glob(full_pattern, flags)

        # On some platforms or Ruby versions, FNM_CASEFOLD may not work properly
        # with complex patterns. If case-insensitive matching returns no results
        # but we expected some, try a more robust approach.
        if results.empty? && !case_sensitive && pattern.match?(/[A-Z]/)
          # Try converting the pattern to lowercase and re-matching
          lowercase_pattern = pattern.downcase
          lowercase_full_pattern = ::File.join(path, lowercase_pattern)
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
      def move_to(target_path)
        target = IOStreams.new(target_path)
        return super(target) unless target.is_a?(self.class)

        authorize!
        target.authorize!
        target.mkpath
        # In case the file is being moved across partitions
        FileUtils.move(path, target.to_s)
        target
      end

      def mkpath
        authorize!
        dir = ::File.dirname(path)
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
        existing = ::File.absolute_path?(path) ? path : ::File.join(Dir.pwd, path)
        missing  = []
        until present?(existing)
          parent = ::File.dirname(existing)
          break if parent == existing

          missing.unshift(::File.basename(existing))
          existing = parent
        end

        if missing.intersect?([".", ".."])
          raise(Errors::AccessDenied, "Access denied to #{path}: '.' and '..' are not allowed after a missing directory")
        end

        ::File.join(::File.realpath(existing), *missing)
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
