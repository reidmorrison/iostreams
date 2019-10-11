require 'fileutils'

module IOStreams
  module Paths
    class File < IOStreams::Path
      # Yields the path to a temporary file_name.
      #
      # File is deleted upon completion if present.
      def self.temp_file_name(basename, extension = '')
        result = nil
        ::Dir::Tmpname.create([basename, extension]) do |tmpname|
          result = yield(tmpname)
        ensure
          ::File.unlink(tmpname) if ::File.exist?(tmpname)
        end
        result
      end

      # Returns a path to a temporary file
      def self.temp_file(basename, extension = '')
        result = nil
        ::Dir::Tmpname.create([basename, extension]) do |tmpname|
          result = yield(new(tmpname).stream(:none))
        ensure
          ::File.unlink(tmpname) if ::File.exist?(tmpname)
        end
        result
      end

      # Used by writers that can write directly to file to create the target path
      def self.mkpath(path)
        dir = ::File.dirname(path)
        FileUtils.mkdir_p(dir) unless ::File.exist?(dir)
      end

      # Yields Paths within the current path.
      #
      # Examples:
      #
      # # Case Insensitive file name lookup:
      # IOStreams::Paths::File.new("ruby").glob("r*.md") { |name| puts name }
      #
      # # Case Sensitive file name lookup:
      # IOStreams::Paths::File.new("ruby").each("R*.md", case_sensitive: true) { |name| puts name }
      #
      # # Also return the names of directories found during the search:
      # IOStreams::Paths::File.new("ruby").each("R*.md", directories: true) { |name| puts name }
      #
      # # Case Insensitive recursive file name lookup:
      # IOStreams::Paths::File.new("ruby").glob("**/*.md") { |name| puts name }
      #
      # Parameters:
      #   pattern [String]
      #     The pattern is not a regexp, it is a string that may contain the following metacharacters:
      #     `*`    Matches all regular files.
      #     `c*`   Matches all regular files beginning with `c`.
      #     `*c`   Matches all regular files ending with `c`.
      #     `\*c*` Matches all regular files that have `c` in them.
      #
      #     `**` Matches recursively into subdirectories.
      #
      #     `?` Matches any one character.
      #
      #     `[set]` Matches any one character in the supplied `set`.
      #     `[^set]` Does not matches any one character in the supplied `set`.
      #
      #     `\` Escapes the next metacharacter..
      #
      #     `{a,b}` Matches on either pattern `a` or pattern `b`.
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
      #    File.fnmatch('cat',       'cat')        #=> true  # match entire string
      #    File.fnmatch('cat',       'category')   #=> false # only match partial string
      #
      #    File.fnmatch('c{at,ub}s', 'cats')                    #=> false # { } isn't supported by default
      #    File.fnmatch('c{at,ub}s', 'cats', File::FNM_EXTGLOB) #=> true  # { } is supported on FNM_EXTGLOB
      #
      #    File.fnmatch('c?t',     'cat')          #=> true  # '?' match only 1 character
      #    File.fnmatch('c??t',    'cat')          #=> false # ditto
      #    File.fnmatch('c*',      'cats')         #=> true  # '*' match 0 or more characters
      #    File.fnmatch('c*t',     'c/a/b/t')      #=> true  # ditto
      #    File.fnmatch('ca[a-z]', 'cat')          #=> true  # inclusive bracket expression
      #    File.fnmatch('ca[^t]',  'cat')          #=> false # exclusive bracket expression ('^' or '!')
      #
      #    File.fnmatch('cat', 'CAT')                     #=> false # case sensitive
      #    File.fnmatch('cat', 'CAT', File::FNM_CASEFOLD) #=> true  # case insensitive
      #
      #    File.fnmatch('?',   '/', File::FNM_PATHNAME)  #=> false # wildcard doesn't match '/' on FNM_PATHNAME
      #    File.fnmatch('*',   '/', File::FNM_PATHNAME)  #=> false # ditto
      #    File.fnmatch('[/]', '/', File::FNM_PATHNAME)  #=> false # ditto
      #
      #    File.fnmatch('\?',   '?')                       #=> true  # escaped wildcard becomes ordinary
      #    File.fnmatch('\a',   'a')                       #=> true  # escaped ordinary remains ordinary
      #    File.fnmatch('\a',   '\a', File::FNM_NOESCAPE)  #=> true  # FNM_NOESCAPE makes '\' ordinary
      #    File.fnmatch('[\?]', '?')                       #=> true  # can escape inside bracket expression
      #
      #    File.fnmatch('*',   '.profile')                      #=> false # wildcard doesn't match leading
      #    File.fnmatch('*',   '.profile', File::FNM_DOTMATCH)  #=> true  # period by default.
      #    File.fnmatch('.*',  '.profile')                      #=> true
      #
      #    rbfiles = '**' '/' '*.rb' # you don't have to do like this. just write in single string.
      #    File.fnmatch(rbfiles, 'main.rb')                    #=> false
      #    File.fnmatch(rbfiles, './main.rb')                  #=> false
      #    File.fnmatch(rbfiles, 'lib/song.rb')                #=> true
      #    File.fnmatch('**.rb', 'main.rb')                    #=> true
      #    File.fnmatch('**.rb', './main.rb')                  #=> false
      #    File.fnmatch('**.rb', 'lib/song.rb')                #=> true
      #    File.fnmatch('*',           'dave/.profile')                      #=> true
      #
      #    pattern = '*' '/' '*'
      #    File.fnmatch(pattern, 'dave/.profile', File::FNM_PATHNAME)  #=> false
      #    File.fnmatch(pattern, 'dave/.profile', File::FNM_PATHNAME | File::FNM_DOTMATCH) #=> true
      #
      #    pattern = '**' '/' 'foo'
      #    File.fnmatch(pattern, 'a/b/c/foo', File::FNM_PATHNAME)     #=> true
      #    File.fnmatch(pattern, '/a/b/c/foo', File::FNM_PATHNAME)    #=> true
      #    File.fnmatch(pattern, 'c:/a/b/c/foo', File::FNM_PATHNAME)  #=> true
      #    File.fnmatch(pattern, 'a/.b/c/foo', File::FNM_PATHNAME)    #=> false
      #    File.fnmatch(pattern, 'a/.b/c/foo', File::FNM_PATHNAME | File::FNM_DOTMATCH) #=> true
      def self.each(pattern = "*", case_sensitive: false, directories: false, hidden: false)
        flags = 0
        flags |= File::FNM_CASEFOLD unless case_sensitive
        flags |= File::FNM_DOTMATCH unless hidden

        Pathname.glob(pattern, flags) do |full_path|
          next if !directories && full_path.directory?

          yield(self.class.new(full_path.to_s))
        end
        # File.fnmatch(pattern, path, File::FNM_EXTGLOB)
        # Dir.glob
      end

      def mkpath
        self.class.mkpath(path)
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

      def delete(recursively: false)
        return self unless ::File.exist?(path)

        if ::File.directory?(path)
          recursively ? FileUtils.remove_dir(path) : Dir.delete(path)
        else
          ::File.unlink(path)
        end
        self
      end

      # Read from a named file
      def reader(&block)
        ::File.open(path, 'rb') { |io| streams.reader(io, &block) }
      end

      # Write to a named file
      #
      # Note:
      #   If an exception is raised whilst the file is being written to the file is removed to
      #   prevent incomplete / partial files from being created.
      def writer(&block)
        self.class.mkpath(path)
        begin
          ::File.open(path, 'wb') { |io| streams.writer(io, &block) }
        rescue StandardError => e
          ::File.unlink(path) if ::File.exist?(path)
          raise(e)
        end
      end
    end
  end
end
