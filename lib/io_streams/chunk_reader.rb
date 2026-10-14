# frozen_string_literal: true

module IOStreams
  # Reads data that arrives one chunk at a time, such as the ranges of an S3 object, the body of an HTTP response, or
  # the blocks of a decompressor, like an IO, holding only the chunk that is being read.
  #
  # The class that includes it supplies the chunks: `#next_chunk` returns [String] the next chunk, or nil at the end
  # of the data, and `#closed?` answers whether it has been closed, after which every read raises IOError.
  module ChunkReader
    # Returns [String] upto `length` bytes, or nil at the end of the data, or with no length, the rest of the data,
    # like `IO#read`. The bytes replace the contents of `outbuf` when it is supplied.
    def read(length = nil, outbuf = nil)
      check_readable(length)
      data = length.nil? ? read_rest : read_upto(length)
      return data unless outbuf

      outbuf.replace(data.to_s)
      outbuf unless data.nil?
    end

    # Returns [String] upto `maxlen` bytes that have already been received, reading the next chunk only when they
    # have all been read, like `IO#readpartial`. Raises EOFError at the end of the data.
    def readpartial(maxlen, outbuf = nil)
      check_readable(maxlen)
      raise(EOFError, "end of file reached") if maxlen.positive? && !available?

      data = maxlen.zero? ? "".b : take(maxlen)
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
    def gets(separator = $/, limit = nil, chomp: false)
      check_readable
      if separator.is_a?(Integer)
        limit     = separator
        separator = $/
      end
      return "".b if limit&.zero?

      limit     = nil if limit&.negative?
      paragraph = separator == ""
      separator = paragraph ? "\n\n".b : separator&.b
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
        # A separator can start in the part of the line already read, and end in the chunk read now.
        from = line ? [line.bytesize - (separator&.bytesize || 1) + 1, 0].max : 0
        part = take(limit && (limit - (line&.bytesize || 0)))
        line = line ? line << part : part
        next unless separator && (index = line.byteindex(separator, from))

        ending = index + separator.bytesize
        # What follows the separator is all within the chunk read now, so it is left to be read next.
        @chunk_offset -= line.bytesize - ending
        return line.byteslice(0, ending)
      end
      line
    end

    # Returns [String] the line without the separator that ends it, like `IO#gets` with `chomp: true`, which also removes
    # a "\r" before a "\n" separator, as `String#chomp` does.
    def chomp_line(line, separator)
      return line unless line.end_with?(separator)

      size = separator == "\n" && line.end_with?("\r\n") ? 2 : separator.bytesize
      line.byteslice(0, line.bytesize - size)
    end

    # Skips the line endings at the start of the rest of the data, such as the blank lines between paragraphs.
    def skip_line_endings
      while available?
        start = @chunk.index(/[^\n]/n, @chunk_offset)
        return @chunk_offset = start if start

        @chunk_offset = @chunk.bytesize
      end
    end

    # Raises like an IO when it is closed, or the length is negative.
    def check_readable(length = nil)
      raise(IOError, "closed stream") if closed?
      raise(ArgumentError, "negative length #{length} given") if length&.negative?
    end

    def read_upto(length)
      return "".b if length.zero?

      data = nil
      while length.positive? && available?
        part    = take(length)
        length -= part.bytesize
        data ? data << part : data = part
      end
      data
    end

    def read_rest
      data = "".b
      data << take while available?
      data
    end

    # Returns [String] upto `length` bytes of the current chunk, or with no length, the rest of it.
    def take(length = nil)
      part           = length ? @chunk.byteslice(@chunk_offset, length) : @chunk.byteslice(@chunk_offset..)
      @chunk_offset += part.bytesize
      part
    end

    # Returns [true|false] whether there are bytes to read, reading the next chunk that is not empty, which replaces
    # the current one, once the current one has all been read.
    def available?
      return true if @chunk && @chunk_offset < @chunk.bytesize

      while (chunk = next_chunk)
        next if chunk.empty?

        # Without copying a chunk that is already binary.
        @chunk        = chunk.encoding == Encoding::BINARY ? chunk : chunk.b
        @chunk_offset = 0
        return true
      end
      false
    end
  end
end
