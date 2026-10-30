require "cgi"
require "uri"
require "tmpdir"
module IOStreams
  module Utils
    MAX_TEMP_FILE_NAME_ATTEMPTS = 5

    # Replaces the value of a sensitive option for display, see .redact_options.
    FILTERED = "[FILTERED]".freeze

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
    # "X-Api-Key" contains `apikey`. The options in a Hash value, such as `ssh_options:` or `client:`, are redacted the
    # same way, as are those in an Array value, whether its elements are Hashes or `[name, value]` pairs.
    def self.redact_options(options, sensitive_names = [])
      redact_hash(options, sensitive_names.map { |name| normalize_option_name(name) })
    end

    # Returns [Hash] the options of each stream, by its name, such as those supplied to `IOStreams::Stream#stream`, with
    # the value of each sensitive option replaced with FILTERED, as the extension that the block returns for the name of
    # the stream decides, see `IOStreams::Extension#redact_options`.
    #
    # Every value of a stream is replaced when the block returns nil, since no extension can say which are sensitive,
    # and options that are not a Hash are replaced whole, since they cannot say which of their values are sensitive.
    # Options that are nil are kept.
    def self.redact_streams(streams)
      streams.to_h do |name, options|
        next [name, options] if options.nil?
        next [name, FILTERED] unless options.is_a?(Hash)

        extension = yield(name)
        [name, extension ? extension.redact_options(options) : options.transform_values { FILTERED }]
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

    # Log a warning for options that a stream ignores, until they raise `ArgumentError` in v3.0, when reading
    # (type: :reader) or writing (:writer).
    #
    # Those that the stream does not take in the other direction either are deprecated, and report a deprecation
    # warning when they are set, see `IOStreams::Builder#option`.
    def self.warn_unknown_options(unknown, stream, type, valid)
      return if unknown.empty?

      names = unknown.keys.map(&:inspect).join(", ")
      IOStreams.logger&.warn(
        "Ignoring unknown #{unknown.size == 1 ? 'option' : 'options'} #{names} when " \
        "#{type == :reader ? 'reading' : 'writing'} a #{stream.inspect} stream. " \
        "Valid options: #{valid.map(&:inspect).join(', ')}. In v3.0 this will raise ArgumentError."
      )
    end

    # Returns [String] the string as UTF-8 text that can be displayed or logged, such as the name of a file, which is not
    # always valid UTF-8, since a file system stores the bytes that a program gave it: a binary string is read as UTF-8,
    # and each byte that is not valid UTF-8 is shown as `\xHH`.
    #
    # For example the name of a file in Latin-1, `caf\xE9.csv`, is displayed as "caf\\xE9.csv".
    def self.display_text(string)
      text = string.encoding == Encoding::BINARY ? string.dup.force_encoding(Encoding::UTF_8) : string
      return text if text.valid_encoding?

      text.scrub { |bytes| bytes.unpack("C*").map { |byte| format("\\x%02X", byte) }.join }
    end

    # Helper method: Returns [true|false] if a value is blank?
    def self.blank?(value)
      return true if value.nil?
      return value !~ /\S/ if value.is_a?(String)

      value.respond_to?(:empty?) ? value.empty? : !value
    end

    # Text that is blank, see .blank_text?: empty, or only whitespace, as Rails' `String#blank?` matches it.
    BLANK_TEXT = /\A[[:space:]]*\z/
    private_constant :BLANK_TEXT

    # The pattern of BLANK_TEXT in each encoding that it cannot be matched against, such as UTF-16, see .blank_text?.
    @encoded_blank_texts = {}
    @encoded_blank_texts_mutex = Mutex.new

    # The rules below of what is blank apply to the rows and records read and written with a schema, see
    # `IOStreams::Tabular::SchemaMapping`, as IOStreams 3.0 applies them to every file, while a file without a schema
    # keeps those of .blank?.

    # Returns [true|false] whether the text is blank, by the rules of Rails' `String#blank?`: empty, or only whitespace,
    # which is any Unicode whitespace, such as a no-break space (U+00A0) or an ideographic space (U+3000), not only a
    # space, tab, or line ending. Text in an encoding that is not ASCII compatible, such as UTF-16, is matched in its own
    # encoding, as Rails matches it.
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
    # record of JSON whose every value is null.
    def self.blank_row?(row)
      case row
      when nil then true
      when ::Hash then row.each_value.all? { |value| blank_value?(value) }
      when ::Array then row.all? { |value| blank_value?(value) }
      else false
      end
    end

    # Returns [Regexp] the pattern of blank text in the supplied encoding, see .blank_text?, created once for each one.
    def self.encoded_blank_text(encoding)
      @encoded_blank_texts_mutex.synchronize do
        @encoded_blank_texts[encoding] ||=
          Regexp.new(BLANK_TEXT.source.encode(encoding), BLANK_TEXT.options | Regexp::FIXEDENCODING)
      end
    end
    private_class_method :encoded_blank_text

    # Returns [String] the text, taken as UTF-8 when it is binary, as IOStreams 2 reads a file without an encoding,
    # see `IOStreams::Stream#encoding`, such as a file read with a schema, whose text is UTF-8, see
    # `IOStreams::Stream#schema`. Text in any other encoding is returned as it is.
    #
    # Raises `IOStreams::Errors::InvalidEncoding` when it is not valid UTF-8.
    def self.utf8(text)
      return text unless text.encoding == ::Encoding::BINARY

      utf8 = text.dup.force_encoding(::Encoding::UTF_8)
      return utf8 if utf8.valid_encoding?

      raise(invalid_utf8(utf8))
    end

    # Returns [IOStreams::Errors::InvalidEncoding] the error for text taken as UTF-8 that is not valid UTF-8, naming
    # its first invalid character, and the line that it is on when the number of the line that the text starts on is
    # supplied, counting the line breaks within the text, such as within a quoted CSV value.
    def self.invalid_utf8(utf8, line_number: nil)
      invalid = nil
      utf8.each_char do |char|
        unless char.valid_encoding?
          invalid = char.b
          break
        end
        line_number += 1 if line_number && char == "\n"
      end
      on_line = line_number ? " on line #{line_number}" : ""
      IOStreams::Errors::InvalidEncoding.new(
        "#{invalid.inspect} is not valid UTF-8#{on_line}. Set the encoding of the file with #encoding",
        line_number:          line_number,
        error_char:           invalid,
        source_encoding:      ::Encoding::BINARY,
        destination_encoding: ::Encoding::UTF_8
      )
    end

    # Returns a frozen copy of the value, whose Hashes, Arrays and Strings are frozen copies too, so that holding a
    # setting, such as a schema, does not freeze the objects that the caller supplied, and the caller changing them
    # does not change the setting. Any other value, such as a Symbol, is returned as it is.
    def self.frozen_copy(value)
      case value
      when Hash then value.to_h { |key, item| [frozen_copy(key), frozen_copy(item)] }.freeze
      when Array then value.map { |item| frozen_copy(item) }.freeze
      when String then value.frozen? ? value : value.dup.freeze
      else value
      end
    end

    # Yields the path to a temporary file_name.
    #
    # File is deleted upon completion if present.
    def self.temp_file_name(basename, extension = "")
      result = nil
      ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir, max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        result = yield(tmpname)
      ensure
        ::FileUtils.rm_f(tmpname)
      end
      result
    end

    # Yields the name of a new, empty temporary file that only the current user can read or write.
    #
    # The file is created exclusively, so that an existing file, or a link planted in a shared
    # temp directory, is never written to. Only a name collision when creating the file is retried,
    # and the file is only deleted once it was created here, so that another process's file is never removed.
    #
    # Returns the value from the block.
    def self.private_temp_file(basename, extension = "")
      file_name = ::Dir::Tmpname.create([basename, extension], IOStreams.temp_dir,
                                        max_try: MAX_TEMP_FILE_NAME_ATTEMPTS) do |tmpname|
        ::File.open(tmpname, ::File::WRONLY | ::File::CREAT | ::File::EXCL, 0o600, &:close)
      end

      begin
        yield(file_name)
      ensure
        ::FileUtils.rm_f(file_name)
      end
    end

    module PathName
      # The byte of the separator of the names in a path, `/`, which every encoding that a path can be in, those that are
      # ASCII-compatible, holds as this byte, see .join.
      SEPARATOR = "/".ord
      private_constant :SEPARATOR

      # The byte of the `.` that starts the extension of a name, see .extname.
      DOT = ".".ord
      private_constant :DOT

      # Whether `::File.join`, `::File.dirname`, `::File.extname` and `::File.basename` keep the bytes of a name that is
      # not valid UTF-8, as CRuby does, rather than changing them, as JRuby does, see
      # https://github.com/jruby/jruby/issues/9880, such as the name of a file in Latin-1 that SFTP lists as bytes, or
      # that is labelled UTF-8, so that the path no longer names the file. Found by what they do, so that
      # IOStreams uses them again once JRuby keeps the bytes.
      FILE_KEEPS_NAMES =
        begin
          name  = "a\xE9".b
          label = name.dup.force_encoding(Encoding::UTF_8)
          ::File.join(name, name).b == "a\xE9/a\xE9".b && ::File.dirname("#{name}/x").b == name &&
            ::File.extname("x.".b + name).b == ".a\xE9".b && ::File.basename("x/#{label}").b == name
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

      # Returns [String] the last name of the supplied path, as `::File.basename` returns it, without the supplied
      # suffix when it ends with it, see .join.
      def self.basename(path, suffix = nil)
        return basename_of(path, suffix) unless FILE_KEEPS_NAMES

        suffix.nil? ? ::File.basename(path) : ::File.basename(path, suffix)
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

      # Returns [String] the last name of the supplied path, as CRuby's `File.basename` returns it on POSIX, by its
      # bytes: the name after its last separators, without the separators at its end, `/` for a path of only
      # separators, in the encoding of the path. The supplied suffix is removed when the name ends with it, `.*` removes
      # the extension of the name, see .extname, and a character followed by `*` removes the name from the last of that
      # character, unless that would leave nothing. A suffix without an encoding in common with the path is not
      # removed.
      #
      # Raises ArgumentError, as CRuby does, when the first character of the suffix, or for a character followed by
      # `*`, a character of the name, is not valid in the encoding that they have in common.
      #
      # Used where `::File.basename` changes names, see .basename, and public, so that its tests compare it with CRuby's.
      def self.basename_of(path, suffix = nil)
        return path.dup if path.empty?

        start = leading_separators(path)
        return path.byteslice(start - 1, 1) if start == path.bytesize

        separator = last_separator(path, start)
        if separator
          start = separator
          start += 1 while path.getbyte(start) == SEPARATOR
        end
        length   = trailing_separators(path) - start
        encoding = suffix && Encoding.compatible?(path, suffix)
        kept     = encoding ? without_suffix(path, start, length, suffix.dup.force_encoding(encoding)) : 0
        path.byteslice(start, kept.positive? ? kept : length)
      end

      # Returns [Integer] the number of bytes of the name of the supplied length, from the supplied position of the
      # supplied path, that are kept once the supplied suffix is removed, see .basename_of, or 0 when the suffix is not
      # removed, as CRuby's `rmext` does.
      def self.without_suffix(path, start, length, suffix)
        return 0 if suffix.empty?

        first = valid_character(suffix[0])
        if suffix.bytesize == first.bytesize + 1 && suffix.getbyte(first.bytesize) == "*".ord
          return stem_length(path, start, length) if first == "."

          name  = valid_character(path.byteslice(start, length).force_encoding(suffix.encoding))
          index = name.rindex(first)
          return index ? name[0, index].bytesize : length
        end
        return length if length < suffix.bytesize

        from = start + length - suffix.bytesize
        return 0 unless character_start?(path, from, suffix.encoding)

        path.byteslice(from, suffix.bytesize).b == suffix.b ? length - suffix.bytesize : 0
      end

      # Returns [String] the supplied text.
      #
      # Raises ArgumentError when it is not valid in its encoding, as CRuby does when it reads its characters.
      def self.valid_character(text)
        return text if text.valid_encoding?

        raise(ArgumentError, "invalid byte sequence in #{text.encoding}")
      end
      private_class_method :valid_character
      private_class_method :without_suffix

      # Returns [Integer] the number of bytes of the name of the supplied length, from the supplied position of the
      # supplied path, before its extension, see .extname_of: before its last `.`, unless only dots start the name.
      def self.stem_length(path, start, length)
        position = start
        position += 1 while position - start < length && path.getbyte(position) == DOT
        dot = nil
        while position - start < length
          dot = position if path.getbyte(position) == DOT
          position += 1
        end
        dot ? dot - start : length
      end
      private_class_method :stem_length

      # Returns [true|false] whether a character of the supplied path, read in the supplied encoding, starts at the
      # supplied position: always for a single byte encoding, and for UTF-8 unless its byte continues a character.
      def self.character_start?(path, position, encoding)
        return true unless encoding == Encoding::UTF_8

        !(0x80..0xBF).cover?(path.getbyte(position))
      end
      private_class_method :character_start?

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

    class URI
      attr_reader :scheme, :hostname, :path, :user, :password, :port, :query

      def initialize(url)
        url       = url.gsub(" ", "%20")
        uri       = ::URI.parse(url)
        @scheme   = uri.scheme
        @hostname = uri.hostname
        @path     = CGI.unescape(uri.path)
        @user     = uri.user
        @password = uri.password
        @port     = uri.port
        return unless uri.query

        @query = {}
        ::URI.decode_www_form(uri.query).each { |key, value| @query[key] = value }
      end
    end
  end
end
