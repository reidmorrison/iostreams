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
    # Those that the stream does not take in the other direction either are deprecated, and also report a deprecation
    # warning, see `IOStreams::Deprecation`. One option hash is shared by the reader and the writer of a stream, so v3.0
    # accepts an option of the other direction, and ignores it, which the class registered for the other direction
    # answers with its `known_option_names`, see `IOStreams.register_extension`.
    def self.warn_unknown_options(unknown, stream, type, valid)
      return if unknown.empty?

      names = unknown.keys.map(&:inspect).join(", ")
      IOStreams.logger&.warn(
        "Ignoring unknown #{unknown.size == 1 ? 'option' : 'options'} #{names} when " \
        "#{type == :reader ? 'reading' : 'writing'} a #{stream.inspect} stream. " \
        "Valid options: #{valid.map(&:inspect).join(', ')}. In v3.0 this will raise ArgumentError."
      )
      warn_deprecated_options(unknown.keys - other_option_names(stream, type), stream)
    end

    # Reports that the options, which the stream ignores in both directions, are deprecated.
    def self.warn_deprecated_options(names, stream)
      return if names.empty?

      keywords = names.map { |name| "#{name}:" }.join(", ")
      Deprecation.warn("#{keywords} #{names.size == 1 ? 'is' : 'are'} deprecated for a #{stream.inspect} stream, " \
                       "which ignores #{names.size == 1 ? 'it' : 'them'}, so remove #{names.size == 1 ? 'it' : 'them'}")
    end
    private_class_method :warn_deprecated_options

    # Returns [Array<Symbol>] the options that the class registered for the stream in the other direction takes, or
    # none when it does not answer them.
    def self.other_option_names(stream, type)
      other = IOStreams.extensions[stream]&.public_send(type == :reader ? :writer_class : :reader_class)
      other.respond_to?(:known_option_names) ? other.known_option_names : []
    end
    private_class_method :other_option_names

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
