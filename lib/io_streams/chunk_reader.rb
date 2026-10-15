# frozen_string_literal: true

module IOStreams
  # Reads data that arrives one chunk at a time, such as the ranges of an S3 object, the body of an HTTP response, or
  # the blocks of a decompressor, like an IO, holding only the chunk that is being read.
  #
  # The class that includes it supplies the chunks: `#next_chunk` returns [String] the next chunk, or nil at the end
  # of the data, and `#closed?` answers whether it has been closed, after which every read raises IOError.
  #
  # The chunks are bytes, which are read as binary strings, unless `#chunk_encoding` returns the encoding of their text,
  # such as the text that the encode stream converts, see `IOStreams::Encode::Reader`. Then each chunk must hold whole
  # characters, and the text is read like an IO that reads text in an encoding, such as
  # `File.open(name, "r:Windows-1252:UTF-8")`: what is read is in the encoding of the text, a limit that would split a
  # character reads to the end of it, and a separator is only found at the start of a character.
  module ChunkReader
    # Returns [String] upto `length` bytes, or nil at the end of the data, or with no length, the rest of the data,
    # like `IO#read`. The bytes replace the contents of `outbuf` when it is supplied.
    #
    # Text is read in its encoding, where `IO#read` with a length reads bytes, and in whole characters: upto `length`
    # bytes of them, or the first character when it is longer, so that each read returns at least one. A read with a
    # length returns the text before data that is not valid in its encoding, and the next read raises
    # IOStreams::Errors::InvalidEncoding for it, so that a reader of lines, such as `IOStreams::Line::Reader`, can read
    # every line before it.
    def read(length = nil, outbuf = nil)
      check_readable(length)
      data = length.nil? ? read_rest : read_upto(length)
      return data unless outbuf

      outbuf.replace(data.to_s)
      outbuf unless data.nil?
    end

    # Returns [String] upto `maxlen` bytes that have already been received, reading the next chunk only when they
    # have all been read, like `IO#readpartial`. Raises EOFError at the end of the data. Text is read in its encoding,
    # and in whole characters, see #read.
    def readpartial(maxlen, outbuf = nil)
      check_readable(maxlen)
      raise(EOFError, "end of file reached") if maxlen.positive? && !available?

      data = maxlen.zero? ? empty_string : take(maxlen)
      outbuf ? outbuf.replace(data) : data
    end

    # Returns [true|false] whether all of the data has been read, reading the next chunk to find out, like
    # `IO#eof?`.
    def eof?
      check_readable
      !available?
    end

    alias eof eof?

    # Returns [String] the next line, ending with the separator, or the rest of the data, or nil at its end, like
    # `IO#gets`, so that code that reads an IO a line at a time, such as `CSV.new(io)`, reads any stream.
    #
    # Like IO, a limit returns at most that many bytes, a limit of 0 an empty string, and a negative limit is no limit,
    # `chomp: true` removes the separator, the separator nil reads the rest of the data, and the separator "" reads
    # paragraphs, which end at a blank line, skipping the line endings before each one and after the blank line that
    # ends it.
    #
    # Text is read like an IO that reads text in an encoding: a limit that would split a character reads to the end of
    # it, and a separator is only found at the start of a character. A separator in the encoding of the text, or of
    # ASCII characters, which are converted to it, separates its lines. Raises ArgumentError for a separator in another
    # encoding, like IO, since its characters are not those of the text.
    def gets(separator = $/, limit = nil, chomp: false)
      check_readable
      if separator.is_a?(Integer)
        limit     = separator
        separator = $/
      end
      return empty_string if limit&.zero?

      limit     = nil if limit&.negative?
      paragraph = separator == ""
      separator = paragraph ? encoded("\n\n") : line_separator(separator)
      skip_line_endings if paragraph

      line = read_line(separator, limit)
      return if line.nil?

      skip_line_endings if paragraph && line.end_with?(separator)
      chomp && separator ? chomp_line(line, separator) : line
    end

    # Returns [String] the next line, see #gets, like `IO#readline`, which raises EOFError at the end of the data.
    def readline(...)
      gets(...) || raise(EOFError, "end of file reached")
    end

    # Yields each line, see #gets, like `IO#each_line`. Returns self, or an Enumerator without a block.
    def each_line(separator = $/, limit = nil, chomp: false, &block)
      return enum_for(__method__, separator, limit, chomp: chomp) unless block

      read_lines(__method__, separator, limit, chomp, &block)
      self
    end

    alias each each_line

    # Returns [Array<String>] the rest of the lines, see #gets, like `IO#readlines`.
    def readlines(separator = $/, limit = nil, chomp: false)
      lines = []
      read_lines(__method__, separator, limit, chomp) { |line| lines << line }
      lines
    end

    private

    # Returns [Encoding] the encoding of the text of the chunks: binary, unless the class that includes this module
    # returns the encoding of the text that its chunks hold, see `IOStreams::Encode::Reader`. A chunk is read in this
    # encoding whatever encoding it is tagged with.
    def chunk_encoding
      Encoding::BINARY
    end

    # Yields each line, see #gets. Raises ArgumentError for a limit of 0, like IO, since every line would be empty, so
    # that the end of the data would never be reached.
    def read_lines(method, separator, limit, chomp)
      raise(ArgumentError, "invalid limit: 0 for #{method}") if (separator.is_a?(Integer) ? separator : limit)&.zero?

      while (line = gets(separator, limit, chomp: chomp))
        yield(line)
      end
    end

    # Returns [String] the bytes up to and including the next separator, or up to the limit, or the rest of the data,
    # or nil at its end, see #gets.
    def read_line(separator, limit)
      line = nil
      while (limit.nil? || line.nil? || line.bytesize < limit) && available?
        remaining = limit && (limit - (line&.bytesize || 0))
        length    = separator && separator_end(line, separator)
        part      = take(remaining && (length.nil? || remaining < length) ? remaining : length)
        line      = line ? line << part : part
        return line if length && part.bytesize == length
      end
      line
    end

    # Returns [Integer] the number of bytes of the current chunk, from the one being read, up to the end of the first
    # separator that ends in it, or nil when none does: a separator that starts at the end of the line already read,
    # or one within the chunk. In text a separator is only found at the start of a character.
    #
    # The chunk is searched rather than a part of it, since Ruby checks the characters of a UTF-8 string before it
    # searches it, once for each string.
    def separator_end(line, separator)
      start = line ? separator[0...-1] : ""
      until start.empty?
        rest = separator.byteslice(start.bytesize..)
        return rest.bytesize if line.end_with?(start) && @chunk.byteslice(@chunk_offset, rest.bytesize) == rest

        start = start[0...-1]
      end
      index = @chunk.byteindex(separator, @chunk_offset)
      index && (index + separator.bytesize - @chunk_offset)
    end

    # Returns [String] the separator in the encoding of the text, see #gets, or as bytes.
    def line_separator(separator)
      encoding = chunk_encoding
      return separator&.b if encoding == Encoding::BINARY
      return separator if separator.nil? || separator.encoding == encoding
      # As US-ASCII, since Ruby cannot convert a binary separator to an encoding that is not ASCII compatible, such as UTF-16.
      return separator.dup.force_encoding(Encoding::US_ASCII).encode(encoding) if separator.ascii_only?

      raise(ArgumentError,
            "Invalid separator #{separator.inspect} in #{separator.encoding}: supply it in the encoding of the text " \
            "that is read, #{encoding}")
    end

    # Returns [String] the line without the separator that ends it, like `IO#gets` with `chomp: true`, which also removes
    # a "\r" before a "\n" separator, as `String#chomp` does.
    def chomp_line(line, separator)
      return line unless line.end_with?(separator)

      carriage_return = encoded("\r\n")
      size = separator == encoded("\n") && line.end_with?(carriage_return) ? carriage_return.bytesize : separator.bytesize
      line.byteslice(0, line.bytesize - size)
    end

    # Skips the line endings at the start of the rest of the data, such as the blank lines between paragraphs.
    def skip_line_endings
      newline = encoded("\n")
      while available?
        start = next_after_line_endings(newline)
        return @chunk_offset = start if start

        @chunk_offset = @chunk.bytesize
      end
    end

    # Returns [Integer] the offset of the first character of the current chunk, from the one being read, that is not
    # the newline, or nil when there is none.
    def next_after_line_endings(newline)
      return @chunk.byteindex(/[^\n]/, @chunk_offset) if newline.encoding.ascii_compatible?

      # Text that is not ASCII compatible, such as UTF-16, cannot be searched with a Regexp.
      offset  = @chunk_offset
      offset += newline.bytesize while @chunk.byteslice(offset, newline.bytesize) == newline
      offset if offset < @chunk.bytesize
    end

    # Raises like an IO when it is closed, or the length is negative.
    def check_readable(length = nil)
      raise(IOError, "closed stream") if closed?
      raise(ArgumentError, "negative length #{length} given") if length&.negative?
    end

    def read_upto(length)
      return empty_string if length.zero?

      data = nil
      while length.positive? && available?
        part = take(length)
        # A character of text that is longer than the rest of the length is left to be read next.
        if data && part.bytesize > length
          @chunk_offset -= part.bytesize
          break
        end

        length -= part.bytesize
        data ? data << part : data = part
      end
      data
    rescue Errors::InvalidEncoding
      # The text before the data that is not valid is returned, and the next read raises, since the next chunk is still
      # not valid.
      raise unless data

      data
    end

    def read_rest
      data = empty_string
      while available?
        # A whole chunk itself, rather than a part of it, which is a new string, whose characters Ruby would check again.
        data << (@chunk_offset.zero? ? @chunk : take)
        @chunk_offset = @chunk.bytesize
      end
      data
    end

    # Returns [String] upto `length` bytes of the current chunk, or with no length, the rest of it.
    #
    # Text is taken in whole characters: a character that `length` would split is left to be read next, unless it is
    # the first, which is taken whole, so that each part holds at least one character.
    def take(length = nil)
      length         = whole_characters(length) if length && @chunk.encoding != Encoding::BINARY
      part           = length ? @chunk.byteslice(@chunk_offset, length) : @chunk.byteslice(@chunk_offset..)
      @chunk_offset += part.bytesize
      part
    end

    # Returns [Integer] the number of bytes of the whole characters of text, from the one being read, within the
    # length, or the bytes of the first character, when it is longer, see #take.
    def whole_characters(length)
      return length if @chunk_offset + length >= @chunk.bytesize
      return utf8_whole_characters(length) if @chunk.encoding == Encoding::UTF_8

      # The text of a chunk is valid, so its bytes from a character to a position are valid when the position starts a
      # character. No character of an encoding that Ruby supports is longer than 4 bytes.
      fewer = (0..3).find { |count| count < length && valid_text?(length - count) }
      return length - fewer if fewer

      more = (1..3).find { |count| valid_text?(length + count) }
      more ? length + more : length
    end

    # Returns [true|false] whether the bytes of the chunk from the one being read upto the length are valid text.
    def valid_text?(length)
      @chunk.byteslice(@chunk_offset, length).valid_encoding?
    end

    # Returns [Integer] the number of bytes of the whole characters of UTF-8 text within the length, see
    # #whole_characters, which finds the start of a character by its first byte, since every other byte of a
    # character is 0b10xxxxxx.
    def utf8_whole_characters(length)
      ending = @chunk_offset + length
      start  = ending
      start -= 1 while start > @chunk_offset && start > ending - 4 && utf8_continuation?(start)
      return start - @chunk_offset if start > @chunk_offset || !utf8_continuation?(ending)

      # The first character is longer than the length.
      ending += 1 while ending < @chunk.bytesize && ending < @chunk_offset + 4 && utf8_continuation?(ending)
      ending - @chunk_offset
    end

    # Returns [true|false] whether the byte of the chunk at the offset continues a UTF-8 character.
    def utf8_continuation?(offset)
      (@chunk.getbyte(offset) & 0xC0) == 0x80
    end

    # Returns [String] the ASCII characters in the encoding of the chunks, see #chunk_encoding.
    def encoded(characters)
      characters.encode(chunk_encoding)
    end

    # Returns [String] an empty string in the encoding of the chunks, see #chunk_encoding.
    def empty_string
      String.new(encoding: chunk_encoding)
    end

    # Returns [true|false] whether there are bytes to read, reading the next chunk that is not empty, which replaces
    # the current one, once the current one has all been read.
    def available?
      return true if @chunk && @chunk_offset < @chunk.bytesize

      encoding = chunk_encoding
      while (chunk = next_chunk)
        next if chunk.empty?

        # Without copying a chunk that is already in the encoding of the chunks.
        @chunk        = chunk.encoding == encoding ? chunk : chunk.b.force_encoding(encoding)
        @chunk_offset = 0
        return true
      end
      false
    end
  end
end
