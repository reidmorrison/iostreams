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
      # IOStreams.path("ruby").glob("r*.md") { |name| puts name }
      #
      # # Case Sensitive file name lookup:
      # IOStreams.path("ruby").each("R*.md", case_sensitive: true) { |name| puts name }
      #
      # # Also return the names of directories found during the search:
      # IOStreams.path("ruby").each("R*.md", directories: true) { |name| puts name }
      #
      # # Case Insensitive recursive file name lookup:
      # IOStreams.path("ruby").glob("**/*.md") { |name| puts name }
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
      # "*"         ".profile"       false    # wildcard doesn't match leading
      # "*"         ".profile"       true     # period by default.
      # ".*"        ".profile"       true                                   {hidden: true}
      #
      # "**/*.rb"   "main.rb"        false
      # "**/*.rb"   "./main.rb"      false
      # "**/*.rb"   "lib/song.rb"    true
      # "**.rb"     "main.rb"        true
      # "**.rb"     "./main.rb"      false
      # "**.rb"     "lib/song.rb"    true
      # "*"         "dave/.profile"  true
      def each_child(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        flags = 0
        flags |= ::File::FNM_CASEFOLD unless case_sensitive
        flags |= ::File::FNM_DOTMATCH if hidden

        # Dir.each_child("testdir") {|x| puts "Got #{x}" }
        Dir.glob(::File.join(path, pattern), flags) do |full_path|
          next if !directories && ::File.directory?(full_path)

          yield(self.class.new(full_path))
        end
      end

      # Moves this file to the `target_path` by copying it to the new name and then deleting the current file.
      #
      # Notes:
      # - Can copy across buckets.
      def move_to(target_path)
        target = IOStreams.new(target_path)
        return super(target) unless target.is_a?(self.class)

        target.mkpath
        # In case the file is being moved across partitions
        FileUtils.move(path, target.to_s)
        target
      end

      def mkpath
        dir = ::File.dirname(path)
        FileUtils.mkdir_p(dir) unless ::File.exist?(dir)
        self
      end

      def mkdir
        FileUtils.mkdir_p(path) unless ::File.exist?(path)
        self
      end

      def exist?
        ::File.exist?(path)
      end

      def size
        ::File.size(path)
      end

      def delete
        return self unless exist?

        ::File.directory?(path) ? Dir.delete(path) : ::File.unlink(path)
        self
      end

      def delete_all
        return self unless exist?

        ::File.directory?(path) ? FileUtils.remove_dir(path) : ::File.unlink(path)
        self
      end

      # Returns the real path by stripping `.`, `..` and expands any symlinks.
      def realpath
        self.class.new(::File.realpath(path))
      end

      private

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
          ::File.unlink(path) if ::File.exist?(path)
          raise(e)
        end
      end
    end
  end
end
