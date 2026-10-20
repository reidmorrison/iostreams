require "cgi"
require "uri"
require "tmpdir"
module IOStreams
  module Utils
    MAX_TEMP_FILE_NAME_ATTEMPTS = 5

    # Lazy load dependent gem so that it remains a soft dependency.
    def self.load_soft_dependency(gem_name, stream_type, require_name = gem_name)
      require require_name
    rescue LoadError => e
      raise(LoadError, "Please install the gem '#{gem_name}' to support #{stream_type}. #{e.message}")
    end

    # Log a warning for options that a stream ignores, until they raise `ArgumentError` in v3.0.
    def self.warn_unknown_options(unknown, stream, direction, valid)
      return if unknown.empty?

      names = unknown.keys.map(&:inspect).join(", ")
      IOStreams.logger&.warn(
        "Ignoring unknown #{unknown.size == 1 ? 'option' : 'options'} #{names} when #{direction} a #{stream.inspect} " \
        "stream. Valid options: #{valid.map(&:inspect).join(', ')}. In v3.0 this will raise ArgumentError."
      )
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
