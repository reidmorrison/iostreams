require "fileutils"

module IOStreams
  module Paths
    class File < IOStreams::Path
      attr_accessor :create_path

      # A file name within the home directory, `~` or starting with `~/`, rather than `~user` or `~$Book1.xlsx`.
      HOME_DIRECTORY = %r{\A~(?:/|\z)}

      # Parameters:
      #   file_name [String]
      #     The name of the file, relative to the current directory unless it starts with `/`.
      #     A name of `~`, or starting with `~/`, is within the current user's home directory, as with
      #     `sftp://hostname/~/a.txt` for the login directory, so that a configured path can change between
      #     local files and SFTP without changing the code. Use `./~` for a directory called `~` in the current directory.
      #     Or a `file://` url, which is always absolute: `file:///home/user/a.txt`, or `file://localhost/home/user/a.txt`.
      #     A `file://` url can also start with `~` for the home directory, such as `file://~/a.txt` or `file:///~/a.txt`.
      #     Characters in the url such as a space, `?` or `#` must be percent-encoded, for example `%20`.
      def initialize(file_name, create_path: true)
        @create_path = create_path
        file_name    = file_name.to_s
        super(file_name.match?(%r{\Afile://}i) ? self.class.path_from_url(file_name) : self.class.home_path(file_name))
      end

      # Returns [String] the absolute path of a `file://` url.
      def self.path_from_url(url)
        host, separator, path = url[7..].partition("/")
        path                  = "" if separator.empty?
        # `file://~/a.txt` is not a standard file url, since `~` is the host, but it is the same as `file:///~/a.txt`.
        if host == "~"
          host = ""
          path = "~/#{path}"
        end
        unless host.empty? || host.casecmp?("localhost")
          raise(ArgumentError,
                "Invalid file url #{url.inspect}: a file url is absolute, such as 'file:///home/user/a.txt', " \
                "or within the home directory, such as 'file://~/a.txt'. " \
                "Supply a relative path without 'file://', such as 'a.txt'.")
        end
        if path.match?(/[?#]/)
          raise(ArgumentError, "Invalid file url #{url.inspect}: percent-encode '?' as '%3F' and '#' as '%23'.")
        end

        path.match?(HOME_DIRECTORY) ? home_path(::URI.decode_uri_component(path)) : "/#{::URI.decode_uri_component(path)}"
      end

      # Returns [String] the file name with a leading `~` replaced by the home directory, or the file name unchanged.
      def self.home_path(file_name)
        return file_name unless file_name.match?(HOME_DIRECTORY)

        home = file_name.sub(HOME_DIRECTORY) { "#{Dir.home}/" }.chomp("/")
        if ::File.directory?("~")
          IOStreams.logger&.warn(
            "#{file_name} is within the home directory: #{home}. " \
            "Use ./#{file_name} for the directory called ~ in the current directory: #{Dir.pwd}"
          )
        end
        home
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

        # A name without pattern characters is also matched within its directory, so that `case_sensitive` applies.
        matcher   = Matcher.new(pattern, case_sensitive: case_sensitive, hidden: hidden)
        directory = local_directory(matcher.directory)
        # `Dir.glob` ignores FNM_CASEFOLD on a case-sensitive file system, such as on Linux, so it lists every
        # candidate and the matcher matches the pattern. The directory is supplied as `base`, so that
        # characters such as `[` in its name are not pattern characters.
        glob_flags = matcher.hidden? ? ::File::FNM_DOTMATCH : 0
        candidates = Dir.glob(candidate_pattern(matcher.depth), glob_flags, base: directory)
        results    = candidates.filter_map do |name|
          next if ::File.basename(name).match?(/\A\.\.?\z/) || !matcher.match?(name)

          next ::File.join(directory, name) if directory

          # A child of the current directory called `~` is not the home directory.
          name.match?(HOME_DIRECTORY) ? "./#{name}" : name
        end

        results.each do |full_path|
          next if !directories && ::File.directory?(full_path)

          child = self.class.new(full_path)
          yield(child) if allowed_child?(child)
        end
        nil
      end

      # Moves this file to the `target_path` by copying it to the new name and then deleting the current file.
      #
      # Notes:
      # - Can copy across buckets.
      def move_to(target_path)
        target = to_stream(target_path)
        return super(target) unless target.is_a?(self.class)

        authorize!
        target.authorize!
        target.mkpath
        # In case the file is being moved across partitions
        tag_failure { FileUtils.move(path, target.to_s) }
        target
      end

      def mkpath
        authorize!
        dir = ::File.dirname(path)
        tag_failure { FileUtils.mkdir_p(dir) }
        self
      end

      def mkdir
        authorize!
        tag_failure { FileUtils.mkdir_p(path) }
        self
      end

      def exist?
        authorize!
        ::File.exist?(path)
      end

      def size
        authorize!
        tag_failure { ::File.size(path) }
      end

      def size?
        authorize!
        ::File.size?(path)
      end

      def file?
        authorize!
        ::File.file?(path)
      end

      def directory?
        authorize!
        ::File.directory?(path)
      end

      def empty?
        authorize!
        tag_failure { ::File.directory?(path) ? Dir.empty?(path) : ::File.empty?(path) }
      end

      def delete
        authorize!
        return self unless exist?

        tag_failure { ::File.directory?(path) ? Dir.delete(path) : ::File.unlink(path) }
        self
      end

      def delete_all
        authorize!
        return self unless exist?

        tag_failure { ::File.directory?(path) ? FileUtils.remove_dir(path) : ::File.unlink(path) }
        self
      end

      # Returns the real path by stripping `.`, `..` and expands any symlinks.
      def realpath
        authorize!
        self.class.new(tag_failure { ::File.realpath(path) })
      end

      private

      # Returns [Module] the kind of failure that an exception raised by the file system means,
      # see `IOStreams::Path#failure_kind`.
      #
      # A file below another file, such as `a.csv/b.csv`, is not found, as on SFTP and S3.
      def failure_kind(exception)
        case exception
        when Errno::ENOENT, Errno::ENOTDIR
          Errors::NotFound
        end
      end

      # Returns [String] the supplied directory within this path, see `IOStreams::Paths::Matcher#directory`,
      # or nil for the current directory.
      def local_directory(directory)
        return (path unless path.empty?) if directory.empty?

        path.empty? ? directory : ::File.join(path, directory)
      end

      # Returns [String] a pattern for `Dir.glob` that lists every file within the depth that a pattern can match,
      # see `IOStreams::Paths::Matcher#depth`.
      def candidate_pattern(depth)
        depth.nil? ? "**/*" : Array.new(depth + 1, "*").join("/")
      end

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
      #
      # The file is opened before the block is called, so that only a failure to open it is tagged as a failure of
      # this path, see `IOStreams::Errors::StorageError`.
      def stream_reader(&)
        file = tag_failure { ::File.open(path, "rb") }
        begin
          builder.reader(file, &)
        ensure
          file.close
        end
      end

      # Write to file
      #
      # Note:
      #   If an exception is raised whilst the file is being written to the file is removed to
      #   prevent incomplete / partial files from being created.
      def stream_writer(&)
        mkpath if create_path
        begin
          file = tag_failure { ::File.open(path, "wb") }
          begin
            builder.writer(file, &)
          ensure
            file.close
          end
        rescue StandardError => e
          ::FileUtils.rm_f(path)
          raise(e)
        end
      end
    end
  end
end
