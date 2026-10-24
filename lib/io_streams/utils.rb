# frozen_string_literal: true

require "uri"
require "tmpdir"
module IOStreams
  module Utils
    MAX_TEMP_FILE_NAME_ATTEMPTS = 5

    # Replaces the value of a sensitive option for display, see .redact_options.
    FILTERED = "[FILTERED]"

    # Option names whose values are hidden as a precaution, even when they are not declared sensitive.
    # Matched against the name in lower case without `_` or `-`, see .redact_options.
    SENSITIVE_NAME = /passphrase|password|secret|token|credential|auth|apikey|privatekey/
    private_constant :SENSITIVE_NAME

    # Returns [Hash] the options with the value of each sensitive option replaced with FILTERED, so that they can be
    # displayed, for example by `#inspect`, or in a web interface.
    #
    # An option is sensitive when its name is one of the supplied `sensitive_names`, or, as a precaution, contains
    # `passphrase`, `password`, `secret`, `token`, `credential`, `auth`, `apikey` or `privatekey`. Names are compared in
    # lower case, ignoring `_` and `-`, so that `:identity_key` matches the ssh option "IdentityKey", and the header
    # "X-Api-Key" contains `apikey`. The options in a Hash value, such as `ssh_options:` or `headers:`, are redacted the
    # same way, as are those in an Array value, whether its elements are Hashes or `[name, value]` pairs.
    def self.redact_options(options, sensitive_names = [])
      redact_hash(options, sensitive_names.map { |name| normalize_option_name(name) })
    end

    # Returns [Hash] the options of each stream, by its name, such as those supplied to `IOStreams::Stream#stream`, with
    # the value of each sensitive option replaced with FILTERED, as the format that the block returns for the name of the
    # stream decides, see `IOStreams::StreamFormat#redact_options`.
    #
    # Every value of a stream is replaced when the block returns nil, since no format can say which are sensitive, and
    # options that are not a Hash are replaced whole, since they cannot say which of their values are sensitive. Options
    # that are nil are kept.
    def self.redact_streams(streams)
      streams.to_h do |name, options|
        next [name, options] if options.nil?
        next [name, FILTERED] unless options.is_a?(Hash)

        format = yield(name)
        [name, format ? format.redact_options(options) : options.transform_values { FILTERED }]
      end
    end

    def self.redact_hash(options, sensitive)
      options.to_h { |name, value| [name, redact_option(name, value, sensitive)] }
    end
    private_class_method :redact_hash

    # Returns the value of the named option for display, see .redact_options.
    def self.redact_option(name, value, sensitive)
      key = normalize_option_name(name)
      return FILTERED if sensitive.include?(key) || key.match?(SENSITIVE_NAME)

      redact_value(value, sensitive)
    end
    private_class_method :redact_option

    # Returns the value with the options within it redacted, when it is a Hash or an Array, see .redact_options.
    def self.redact_value(value, sensitive)
      case value
      when Hash
        redact_hash(value, sensitive)
      when Array
        value.map do |element|
          if element.is_a?(Array) && element.size == 2 && (element.first.is_a?(String) || element.first.is_a?(Symbol))
            [element.first, redact_option(element.first, element.last, sensitive)]
          else
            redact_value(element, sensitive)
          end
        end
      else
        value
      end
    end
    private_class_method :redact_value

    def self.normalize_option_name(name)
      name.to_s.downcase.delete("_-")
    end
    private_class_method :normalize_option_name

    # Lazy load dependent gem so that it remains a soft dependency.
    def self.load_soft_dependency(gem_name, stream_type, require_name = gem_name)
      require require_name
    rescue LoadError => e
      raise(LoadError, "Please install the gem '#{gem_name}' to support #{stream_type}. #{e.message}")
    end

    # Returns [true|false] whether the soft dependency is installed, loading it when it is, see .load_soft_dependency.
    #
    # Raises LoadError when the gem is installed but cannot be loaded, such as when a gem that it requires is missing,
    # so that a broken installation is reported, rather than treated as a gem that is not installed.
    def self.soft_dependency_installed?(gem_name, stream_type, require_name = gem_name)
      load_soft_dependency(gem_name, stream_type, require_name)
      true
    rescue LoadError => e
      raise unless e.cause.is_a?(LoadError) && e.cause.path == require_name

      false
    end

    # Text that is blank, see .blank_text?: empty, or only whitespace, as Rails' `String#blank?` matches it.
    BLANK_TEXT = /\A[[:space:]]*\z/
    private_constant :BLANK_TEXT

    # The pattern of BLANK_TEXT in each encoding that it cannot be matched against, such as UTF-16, see .blank_text?.
    @encoded_blank_texts = {}
    @encoded_blank_texts_mutex = Mutex.new

    # Returns [true|false] whether the value is blank, by the rules of Rails' `Object#blank?`: nil, false, text that is
    # blank, see .blank_text?, or anything else that is empty, such as an empty Array or Hash. Any other value is not
    # blank, such as true or 0.
    #
    # Raises ArgumentError for text whose bytes are not valid in its encoding, as Rails does.
    def self.blank?(value)
      return true if value.nil?
      return blank_text?(value) if value.is_a?(String)

      value.respond_to?(:empty?) ? value.empty? : !value
    end

    # Returns [true|false] whether the text is blank, by the rules of Rails' `String#blank?`: empty, or only whitespace,
    # which is any Unicode whitespace, such as a no-break space (U+00A0) or an ideographic space (U+3000), not only a
    # space, tab, or line ending. A zero width space (U+200B) and a byte order mark (U+FEFF) are not whitespace. Text in
    # an encoding that is not ASCII compatible, such as UTF-16, is matched in its own encoding, as Rails matches it.
    #
    # Raises ArgumentError for text whose bytes are not valid in its encoding, as Rails does.
    def self.blank_text?(text)
      text.empty? || BLANK_TEXT.match?(text)
    rescue Encoding::CompatibilityError
      encoded_blank_text(text.encoding).match?(text)
    end

    # Returns [true|false] whether a value within a row or record is blank, so that it holds no data: nil, or text that
    # is blank, see .blank_text?. Any other value is data, such as false, 0, an empty Array, or text whose bytes are not
    # valid in its encoding, since it is not text that is known to be blank.
    def self.blank_value?(value)
      value.nil? || (value.is_a?(String) && value.valid_encoding? && blank_text?(value))
    end

    # Returns [true|false] whether a row or record is blank, so that it holds no data: nil, or an Array or Hash without
    # values, or whose every value is blank, see .blank_value?, such as the row of a line of CSV of only commas, or a
    # record of JSON whose every value is null. Reading treats it as a blank line in every format, see
    # `IOStreams::Tabular::Mapping`.
    def self.blank_row?(row)
      case row
      when nil then true
      when ::Hash then row.each_value.all? { |value| blank_value?(value) }
      when ::Array then row.all? { |value| blank_value?(value) }
      else false
      end
    end

    # Raises ArgumentError unless the value of the option of the supplied name is true or false, rather than take any
    # other value as truthy or falsy, so that a misspelled value, such as `"no"`, is reported.
    def self.check_boolean(name, value)
      return if [true, false].include?(value)

      raise(ArgumentError, "Invalid #{name} #{value.inspect}: supply true or false")
    end

    # Returns [Regexp] the pattern of blank text in the supplied encoding, see .blank_text?, created once for each one.
    def self.encoded_blank_text(encoding)
      @encoded_blank_texts_mutex.synchronize do
        @encoded_blank_texts[encoding] ||=
          Regexp.new(BLANK_TEXT.source.encode(encoding), BLANK_TEXT.options | Regexp::FIXEDENCODING)
      end
    end
    private_class_method :encoded_blank_text

    # Returns [Array<String>] the extensions of the file name, in lower case, for example `["csv", "gz"]` for `"Data.CSV.gz"`.
    # The name of the file before the first `.` is not an extension, so a file named `gz` has no extensions.
    def self.file_name_extensions(file_name)
      parts = matchable(::File.basename(file_name.to_s)).sub(/\A\.+/, "").split(".")
      parts.shift
      parts.map(&:downcase)
    end

    # Returns [Symbol] the name of a file name extension, as it is registered, see `IOStreams.register_extension`, and as
    # the streams of a path are named, see `IOStreams::Builder`: in lower case, since the extensions of a file name are
    # compared without case, see .file_name_extensions, so `:GZ` and `"gz"` are `:gz`. Returns nil for nil.
    def self.extension_name(name)
      name.to_s.downcase.to_sym unless name.nil?
    end

    # The names of a path, which `::File.join`, `::File.dirname` and `::File.extname` join and split, apart from where
    # they change a name that is not valid UTF-8, as JRuby's do, see FILE_KEEPS_NAMES, where it joins and splits them by
    # their bytes, as CRuby does.
    module PathName
      # The byte of the separator of the names in a path, `/`, which every encoding that a path can be in, those that are
      # ASCII-compatible, holds as this byte, see .join.
      SEPARATOR = "/".ord
      private_constant :SEPARATOR

      # The byte of the `.` that starts the extension of a name, see .extname.
      DOT = ".".ord
      private_constant :DOT

      # Whether `::File.join`, `::File.dirname` and `::File.extname` keep the bytes of a name that is not valid UTF-8, as
      # CRuby does, rather than changing them, as JRuby does, see https://github.com/jruby/jruby/issues/9880, such as
      # the name of a file in Latin-1 that SFTP lists as bytes, so that the path no longer names the file. Found by what
      # they do, so that IOStreams uses them again once JRuby keeps the bytes.
      FILE_KEEPS_NAMES =
        begin
          name = "a\xE9".b
          ::File.join(name, name).b == "a\xE9/a\xE9".b && ::File.dirname("#{name}/x").b == name &&
            ::File.extname("x.".b + name).b == ".a\xE9".b
        end

      # Returns [String] the supplied names joined into a path, as `::File.join` joins Strings: with one `/` between
      # each name and the next, whose separators decide which are kept, keeping the bytes and the encoding of each name,
      # where `::File.join` does, see FILE_KEEPS_NAMES, otherwise by .join_names.
      def self.join(*names)
        FILE_KEEPS_NAMES ? ::File.join(*names) : join_names(names)
      end

      # Returns [String] the directory of the supplied path, as `::File.dirname` returns it, see .join.
      def self.dirname(path)
        FILE_KEEPS_NAMES ? ::File.dirname(path) : dirname_of(path)
      end

      # Returns [String] the extension of the last name of the supplied path, as `::File.extname` returns it, see .join.
      def self.extname(path)
        FILE_KEEPS_NAMES ? ::File.extname(path) : extname_of(path)
      end

      # Returns [String] the supplied Strings joined into a path, as CRuby's `File.join` joins them on POSIX, by their
      # bytes: each name after the first is joined to the path so far with one `/`, unless the path ends with `/`, when
      # it is added as it is, or the name starts with `/`, when the path loses its trailing `/` before it. The path starts
      # in the encoding of the first name, and takes that of a name whose text needs it, as for `String#<<`, which raises
      # `Encoding::CompatibilityError` for names that have no encoding in common.
      #
      # Used where `::File.join` changes names, see .join, and public, so that its tests compare it with CRuby's.
      def self.join_names(names)
        joined = String.new(encoding: names.first&.encoding || Encoding::BINARY)
        names.each_with_index do |name, index|
          if index.positive?
            tail = trailing_separators(joined)
            if name.getbyte(0) == SEPARATOR
              joined = joined.byteslice(0, tail)
            elsif tail == joined.bytesize
              joined << "/"
            end
          end
          joined << name
        end
        joined
      end

      # Returns [String] the directory of the supplied path, as CRuby's `File.dirname` returns it on POSIX, by its bytes:
      # the path before the separators of its last name, `/` for a path of only separators, or `.` for a single name, in
      # the encoding of the path.
      #
      # Used where `::File.dirname` changes names, see .dirname, and public, so that its tests compare it with CRuby's.
      def self.dirname_of(path)
        root   = leading_separators(path)
        start  = root > 1 ? root - 1 : 0
        finish = last_separator(path, root) || root
        return String.new(".", encoding: path.encoding) if finish == start

        path.byteslice(start, finish - start)
      end

      # Returns [String] the extension of the last name of the supplied path, as CRuby's `File.extname` returns it on
      # POSIX, by its bytes: from its last `.`, unless only dots start the name, in the encoding of the path, or an
      # empty String when it has none.
      #
      # Used where `::File.extname` changes names, see .extname, and public, so that its tests compare it with CRuby's.
      def self.extname_of(path)
        separator = last_separator(path, 0)
        position  = separator ? separator + 1 : 0
        position += 1 while position < path.bytesize && path.getbyte(position) == SEPARATOR
        position += 1 while position < path.bytesize && path.getbyte(position) == DOT
        dot = nil
        while position < path.bytesize
          byte = path.getbyte(position)
          break if byte == SEPARATOR

          dot = position if byte == DOT
          position += 1
        end
        return "".b if dot.nil?

        path.byteslice(dot, position - dot)
      end

      # Returns [Integer] the number of bytes of the supplied path before the separators at its end.
      def self.trailing_separators(path)
        tail = path.bytesize
        tail -= 1 while tail.positive? && path.getbyte(tail - 1) == SEPARATOR
        tail
      end
      private_class_method :trailing_separators

      # Returns [Integer] the number of separators at the start of the supplied path.
      def self.leading_separators(path)
        count = 0
        count += 1 while count < path.bytesize && path.getbyte(count) == SEPARATOR
        count
      end
      private_class_method :leading_separators

      # Returns [Integer] the position of the first of the last separators of the supplied path, from the supplied
      # position on, that a name follows, or nil when it has none, as CRuby's `strrdirsep` finds it.
      def self.last_separator(path, from)
        last     = nil
        position = from
        while position < path.bytesize
          if path.getbyte(position) == SEPARATOR
            separator = position
            position += 1 while position < path.bytesize && path.getbyte(position) == SEPARATOR
            break if position >= path.bytesize

            last = separator
          else
            position += 1
          end
        end
        last
      end
      private_class_method :last_separator
    end

    # Returns [String] the supplied string, or its bytes when it is not valid in its encoding, so that a Regexp,
    # `split` or `File.fnmatch?` can be applied to it, since Ruby raises ArgumentError for those otherwise.
    #
    # For example the name of a file that a program wrote in Latin-1 to a file system of UTF-8 names, such as
    # `caf\xE9.csv` on Linux, is not valid UTF-8. Its bytes are used as they are, so that the file can still be
    # found, matched and opened by its name.
    def self.matchable(string)
      string.valid_encoding? ? string : string.b
    end

    # Returns [String] the supplied string as valid UTF-8, to display or log it: a binary string is read as UTF-8,
    # and each byte that is still not valid UTF-8 is shown as `\xHH`, as `String#inspect` shows it.
    #
    # For example the name of a file in Latin-1, `caf\xE9.csv`, is displayed as "caf\\xE9.csv".
    def self.display_text(string)
      text = string.encoding == Encoding::BINARY ? string.dup.force_encoding(Encoding::UTF_8) : string
      return text if text.valid_encoding?

      text.scrub { |bytes| bytes.unpack("C*").map { |byte| format("\\x%02X", byte) }.join }
    end

    # Yields the path to a temporary file_name.
    #
    # The file is not created, and is deleted upon completion if present.
    #
    # Only the name is chosen within `Dir::Tmpname.create`, which retries whenever its block raises
    # `Errno::EEXIST`, so that the supplied block is never run again when it raises `Errno::EEXIST` itself.
    def self.temp_file_name(basename, extension = "")
      file_name = ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir,
                                        max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        raise(Errno::EEXIST, tmpname) if ::File.exist?(tmpname) || ::File.symlink?(tmpname)
      end

      begin
        yield(file_name)
      ensure
        ::FileUtils.rm_f(file_name)
      end
    end

    # Returns [true|false] whether the value names a file rather than being an IO: a String, or a Pathname, such as
    # `Rails.root.join("data.csv")`, so that it is read as the file it names, rather than as an IO.
    def self.file_name?(value)
      value.is_a?(String) || (defined?(::Pathname) && value.is_a?(::Pathname)) || false
    end

    # Returns a copy of the value, whose Hashes, Arrays and Strings are copies too, so that changing the copy, such as
    # the options of a copy of a path, does not change the value. Any other value, such as a Proc or a Symbol, is
    # returned as it is.
    def self.deep_copy(value)
      case value
      when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
      when Array then value.map { |item| deep_copy(item) }
      when String then value.dup
      else value
      end
    end

    # Returns a frozen copy of the value, whose Hashes, Arrays and Strings are frozen copies too, so that freezing an
    # object that holds options does not freeze the objects that the caller supplied. Any other value, such as a Proc
    # or a Symbol, is returned as it is.
    def self.frozen_copy(value)
      case value
      when Hash then value.to_h { |key, item| [frozen_copy(key), frozen_copy(item)] }.freeze
      when Array then value.map { |item| frozen_copy(item) }.freeze
      when String then value.frozen? ? value : value.dup.freeze
      else value
      end
    end

    # Returns [File] the open local file that the IO reads or writes: the IO itself when it is a `File`, or the file of a
    # `Tempfile`, which delegates to it, also within the `IOStreams::BytesOutput` that the streams write the IO
    # supplied to `IOStreams.stream` through. Returns nil for any other IO, such as a pipe, a socket or a StringIO, and
    # for a file that is closed. A delegator of a `Tempfile` is not unwrapped any further, since it can change what is
    # read, such as by decoding it, so that it is read through its own methods.
    def self.local_file(io)
      io   = io.__getobj__ if io.is_a?(BytesOutput)
      file = defined?(::Delegator) && io.is_a?(::Delegator) ? io.__getobj__ : io
      file if file.is_a?(::File) && !file.closed?
    end

    # Returns [String] the absolute name of the local file that the IO reads, see .local_file, so that a reader that
    # only works on files, such as zip, can open the file itself instead of a temp copy of it.
    #
    # Only when the IO is a regular file at its start, and its name still refers to it, which for example a
    # relative name no longer does after the current directory changes.
    # Returns nil for any other IO, such as a pipe, a socket or a StringIO.
    #
    # The name is absolute so that it still refers to the file when the current directory changes before the
    # reader opens it.
    def self.local_file_name(io)
      file = local_file(io)
      return unless file&.path

      name = ::File.absolute_path(file.path)
      name if file.stat.file? && file.pos.zero? && ::File.identical?(file, name)
    rescue SystemCallError
      nil
    end

    # Returns [true|false] whether the current thread is being killed, such as by `Thread#kill`, and is running its
    # `ensure` blocks, since killing a thread raises no exception that it can rescue.
    def self.thread_aborting?
      Thread.current.status == "aborting"
    end

    # Yields, then calls `finish`, such as to copy or upload what the block wrote, once the block returns, including
    # when it leaves early, such as with `break`, which keeps what was written so far. Calls `abort` instead, such as to
    # remove what the block wrote, when it raises, or its thread is killed while it runs, since what it wrote is not
    # complete.
    #
    # A thread that was already being killed when the block started, such as one whose `ensure` block writes a file as
    # it stops, cannot be killed again, see .thread_aborting?, so the block ran to its end, and is finished.
    #
    # Returns the result of the block.
    def self.finish_or_abort(finish: nil, abort: nil)
      aborting = thread_aborting?
      failed   = false
      begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException -- so that no error finishes what the block did not
        failed = true
        raise
      ensure
        if failed || (!aborting && thread_aborting?)
          abort&.call
        else
          finish&.call
        end
      end
    end

    # Yields the name of a new, empty temporary file that only the current user can read or write.
    #
    # The file is created exclusively, so that an existing file, or a link planted in a shared
    # temp directory, is never written to. Only a name collision when creating the file is retried,
    # and the file is only deleted once it was created here, so that another process's file is never removed.
    #
    # Parameters:
    #   purpose: [String]
    #     What the file holds, such as "the download of s3://bucket/a.csv", which is logged at debug level
    #     via `IOStreams.logger` when the file is created. Its size is logged when it is deleted.
    #
    # Returns the value from the block.
    def self.private_temp_file(basename, extension = "", purpose:)
      file_name = ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir,
                                        max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        ::File.open(tmpname, ::File::WRONLY | ::File::CREAT | ::File::EXCL, 0o600, &:close)
      end
      IOStreams.logger&.debug { "Created temp file #{file_name} for #{purpose}" }

      begin
        yield(file_name)
      ensure
        IOStreams.logger&.debug { "Deleting temp file #{file_name}, which held #{::File.size?(file_name).to_i} bytes" }
        ::FileUtils.rm_f(file_name)
      end
    end

    # Parses an S3, SFTP or other url whose path is the name of an object or file as it is, see `.escape`.
    #
    # Also answers the parts of such a url, by its bytes, so that a url with a name that is not valid UTF-8 can be
    # taken apart and put together again, see `.authority`, `.split`, `.root`, `.without_userinfo_or_query` and
    # `.encode_path`.
    class URI
      attr_reader :scheme, :hostname, :path, :user, :password, :port, :query, :fragment

      # A space, a control character, or a byte of a character that is not ASCII, none of which `::URI` parses.
      UNPARSEABLE_BYTE           = /[^\x21-\x7E]/n
      # The characters that `::URI` does not parse in a path, but that a file name can hold, such as `report [1].csv`.
      UNPARSEABLE_PATH_CHARACTER = /["<>\[\\\]^`{|}]/n
      # Each byte that `::URI` does not parse in a user name or password: any but a letter, a digit, `-._~!$&'()*+,;=`,
      # and `:` between them. Includes `%`, so that a user name or password is taken as it is, see `#user`.
      UNPARSEABLE_USERINFO_BYTE  = /[^A-Za-z0-9\-._~!$&'()*+,;=:]/n
      # The scheme, the user name and password, which end at the last `@`, and the host and port of a url.
      # The host can be an IPv6 address within `[` and `]`.
      AUTHORITY                  = %r{\A(?<scheme>[^:/?#]+://)(?:(?<userinfo>[^/?#]*)@)?(?<host>[^/?#]*)}n
      # The characters that `.new` reads in a path as an escape, the query or a fragment, see `.encode_path`.
      PATH_DELIMITER             = /[%?#]/n
      # The characters that RFC 3986 calls unreserved, which a url can hold anywhere as they are, see `.normalize_escapes`.
      UNRESERVED                 = /\A[A-Za-z0-9\-._~]\z/n
      private_constant :UNPARSEABLE_BYTE, :UNPARSEABLE_PATH_CHARACTER, :UNPARSEABLE_USERINFO_BYTE, :AUTHORITY,
                       :PATH_DELIMITER, :UNRESERVED

      # The user name and password are as they are in the url, including any character that is not ASCII, or `@`,
      # rather than percent-decoded, as they always have been, so that a password such as `p%41ss` is unchanged.
      #
      # Raises ArgumentError when the host has a space, or a character that is not ASCII, or when the url cannot be
      # parsed, see `.parse`.
      def initialize(url)
        uri       = self.class.parse(self.class.escape(url), name: url)
        @scheme   = uri.scheme
        @hostname = uri.hostname
        # Unlike a query string, `+` in a path is not a space.
        @path     = ::URI.decode_uri_component(uri.path)
        @user     = uri.user && ::URI.decode_uri_component(uri.user)
        @password = uri.password && ::URI.decode_uri_component(uri.password)
        @port     = uri.port
        @fragment = uri.fragment
        return unless uri.query

        @query = {}
        ::URI.decode_www_form(uri.query).each { |key, value| @query[key] = value }
      rescue ::URI::InvalidURIError
        # Without the url, which can hold a password, as the cause, since its message is the url.
        raise(ArgumentError, self.class.unparseable(url), cause: nil)
      end

      # Returns [::URI::Generic] the url parsed by `::URI`.
      #
      # Raises ArgumentError when it cannot be parsed, rather than `URI::InvalidURIError`, whose message is the whole
      # url, which can hold a password, or the signature of a pre-signed url in its query. The message names the url,
      # or the supplied name of it, without them, see `.redact`.
      def self.parse(url, name: url)
        ::URI.parse(url)
      rescue ::URI::InvalidURIError
        raise(ArgumentError, unparseable(name), cause: nil)
      end

      # Returns [ArgumentError] for a url that a path of the kind, such as "S3", cannot use, naming the url without
      # its user name, password, query or fragment, see `.without_userinfo_or_query`, and the problem with it.
      def self.invalid(kind, url, problem)
        ArgumentError.new("Invalid #{kind} url #{Utils.display_text(without_userinfo_or_query(url)).inspect}: #{problem}")
      end

      # Returns [String] the message for a url that cannot be parsed, see `.parse`.
      def self.unparseable(url)
        "Invalid url #{redact(url).inspect}: it cannot be parsed. Percent-encode a character that a url cannot hold, " \
          "such as a space as '%20'. For an SFTP or HTTP url, supply a user name or password that has a '/', '?' or " \
          "'#' with the username: and password: arguments."
      end

      # Returns [String] a url that cannot be parsed without anything that could be its user name, password, query or
      # fragment, since its parts cannot be told apart: what is before the last `@` after its scheme is replaced with
      # `[FILTERED]`, and what follows the first `?` or `#` after that is removed. A password can hold a `/`, `?`, `#`
      # or `@`, so they cannot end it.
      def self.redact(url)
        text = Utils.display_text(url.to_s)
        scheme, separator, rest = text.partition("://")
        return text.sub(/[?#].*\z/m, "") if separator.empty?

        _userinfo, at, after = rest.rpartition("@")
        rest = "#{Utils::FILTERED}@#{after}" unless at.empty?
        "#{scheme}://#{rest.sub(/[?#].*\z/m, '')}"
      end

      # Returns [String] the url with each byte that `::URI` cannot parse percent-encoded, to be decoded again with
      # its path, since the path of an S3 or SFTP url is the name of the object or file as it is, such as
      # `s3://bucket/café [1].csv`. A `%`, `?` or `#` in the path is not encoded, since it starts an escape, the query
      # or a fragment. Each byte of the user name and password that `::URI` cannot parse, including `%`, is encoded, to
      # be decoded again, see `#user`.
      #
      # Raises ArgumentError when the host has a space, or a character that is not ASCII, which no store accepts.
      def self.escape(url)
        bytes     = url.b
        authority = AUTHORITY.match(bytes)
        path      = percent_encode(percent_encode(authority ? authority.post_match : bytes, UNPARSEABLE_BYTE),
                                   UNPARSEABLE_PATH_CHARACTER)
        "#{escape_authority(authority)}#{path}".force_encoding(Encoding::UTF_8)
      end

      # Returns [String] the scheme, user name, password, host and port of the url, such as
      # `sftp://jack:secret@example.org:2222`, as they are in the url, or an empty string when it has no scheme.
      def self.authority(url)
        AUTHORITY.match(url.b).to_s.dup.force_encoding(url.encoding)
      end

      # Returns [Array(String, String, String)] the url in three parts, which join to make it again: its scheme, user
      # name, password, host and port, see `.authority`, its path, as it is written, and its query and fragment, such
      # as `["s3://bucket", "/data/*.csv", "?request_payer=requester"]`. A name that is not a url is all path.
      def self.split(url)
        authority = AUTHORITY.match(url.b)
        return ["", url, ""] unless authority

        path, rest = authority.post_match.match(/\A([^?#]*)(.*)\z/mn).captures
        [authority.to_s, path, rest].map { |part| part.force_encoding(url.encoding) }
      end

      # Returns [String] the name that a path of a url, as it is written, holds, such as `a#b.csv` for `a%23b.csv`,
      # decoded as `.new` decodes it.
      def self.decode_path(path)
        ::URI.decode_uri_component(path)
      end

      # Returns [String] the url with the path `/` when it has no path, such as `sftp://host` or `https://host?a=1`,
      # so that the root of a host is always written the same way, like the root of an S3 bucket, `s3://bucket/`.
      def self.root(url)
        authority = AUTHORITY.match(url.b)
        return url unless authority&.post_match&.match?(/\A(?:[?#]|\z)/n)

        "#{authority}/#{authority.post_match}".force_encoding(url.encoding)
      end

      # Returns [String] the url without its user name, password, query or fragment, which can hold credentials or
      # ssh options such as a key, so that it can be displayed, such as `sftp://example.org/data/a.csv`.
      def self.without_userinfo_or_query(url)
        bytes     = url.b
        authority = AUTHORITY.match(bytes)
        origin    = authority ? "#{authority[:scheme]}#{authority[:host]}" : ""
        path      = (authority ? authority.post_match : bytes).sub(/[?#].*\z/mn, "")
        "#{origin}#{path}".force_encoding(url.encoding)
      end

      # Returns [String] the name as the path of a url, with each `%`, `?` and `#` percent-encoded, so that `.new`
      # parses the path of the url as the name again, such as `a%23b.csv` for the file `a#b.csv`.
      # Every other character is as it is, see `.escape`.
      def self.encode_path(name)
        percent_encode(name.b, PATH_DELIMITER).force_encoding(name.encoding)
      end

      # Returns [String] the host and port as a url writes them, such as `example.org:2222`: an IPv6 address within `[`
      # and `]`, such as `[::1]:2222`, so that the port is not read as part of it, and without the port when it is the
      # supplied default port.
      def self.host_and_port(hostname, port, default_port)
        host = hostname.include?(":") ? "[#{hostname}]" : hostname
        port == default_port ? host : "#{host}:#{port}"
      end

      # Returns [String] the supplied part of a url, such as its path or query, with each percent-encoded character
      # spelled as RFC 3986 normalizes it: a letter, digit, `-`, `.`, `_` or `~`, which a url can hold anywhere as it is,
      # is decoded, since it is the same as its percent-encoding, so `%7E` is `~`, and the hexadecimal digits of any
      # other are in upper case, so `%2f` is `%2F`. Any other character is not the same as its percent-encoding, such as
      # `/` and `%2F`, so they are kept apart.
      def self.normalize_escapes(text)
        text.gsub(/%\h\h/) do |escape|
          character = escape.delete_prefix("%").hex.chr
          character.match?(UNRESERVED) ? character : escape.upcase
        end
      end

      # Returns [String] the scheme, user name, password, host and port of the url that `::URI` can parse.
      def self.escape_authority(authority)
        return "" unless authority

        host = authority[:host]
        if host.match?(UNPARSEABLE_BYTE)
          # Without the url, which can hold a password.
          raise(ArgumentError,
                "The host of a url cannot have a space or a character that is not ASCII: " \
                "#{Utils.display_text(host).inspect}. Supply an international domain name in its ASCII form, " \
                "which starts with 'xn--'.")
        end

        userinfo = authority[:userinfo] && "#{percent_encode(authority[:userinfo], UNPARSEABLE_USERINFO_BYTE)}@"
        "#{authority[:scheme]}#{userinfo}#{host}"
      end

      def self.percent_encode(bytes, pattern)
        bytes.gsub(pattern) { |byte| format("%%%02X", byte.ord) }
      end

      private_class_method :escape_authority, :percent_encode, :redact
    end
  end
end
