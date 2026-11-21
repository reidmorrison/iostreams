# frozen_string_literal: true

require "strscan"

module IOStreams
  module Xlsx
    # Reads the XML of a part of a workbook as a stream of events, in chunks, so that a worksheet of any size is read
    # without holding it whole, for the parts that a spreadsheet application writes, rather than any XML document:
    #
    # * An element, its attributes and its text are named by their local name, without a namespace prefix, such as `c`
    #   for `<x:c>`, since the parts of a workbook use one namespace for their elements, of either Transitional or Strict
    #   OOXML.
    # * Its text and the values of its attributes are decoded: the five entities of XML and character references, such as
    #   `&amp;` and `&#13;`, and line breaks as XML normalizes them, so that a CR LF or CR is a LF, while `&#13;` is a CR.
    # * A comment and a processing instruction are skipped, and the text of a CDATA section is text, as it is.
    # * An extension list, `<extLst>`, is skipped with all that it holds, since it is where later versions of Office
    #   add to a part, with elements of their own namespaces whose local names can be those of the elements that are
    #   read, such as the `<x15:workbookPr>` of Excel 2013, which holds no date system, after the `<workbookPr>` that
    #   does.
    # * A document type declaration raises, rather than define entities, so that it never expands one, nor reads another
    #   file, which a workbook has no use for.
    #
    # It scans the bytes of the part, as UTF-8 text, rather than any encoding that its XML declaration names, which every
    # spreadsheet application writes. A part that starts with a UTF-16 byte order mark raises.
    #
    # A handler receives the events:
    #   start_element(name, attributes)  name [String], attributes [Hash<String, String>], by their local names
    #   end_element(name)                also for an element that closes itself, such as `<c r="A1"/>`
    #   text(text)                       text [String], the text between tags, in one or more calls
    class XmlScanner
      # The bytes of a part that are read at a time.
      CHUNK_SIZE = 65_536

      # The most bytes of a tag, of its name and attributes, so that a part that never closes a tag raises, rather than
      # hold the rest of the part.
      LONGEST_TAG = 1_048_576

      # The start of a start tag: the local name of its element. Its attributes are read in turn where they are, rather
      # than as text of their own that is scanned again, which takes half as long again.
      START_TAG = %r{<(?:[^\s/>!?:]+:)?([^\s/>!?:]+)}

      # An attribute of a start tag: its local name and its value, in double or single quotes.
      ATTRIBUTE = %r{\s+(?:[^\s=/>:]+:)?([^\s=/>:]+)\s*=\s*(?:"([^"]*)"|'([^']*)')}

      # The end of a start tag: a `/` when its element closes itself.
      START_TAG_END = %r{\s*(/?)>}

      # The end tag of an element: its local name.
      END_TAG = %r{</(?:[^\s/>:]+:)?([^\s/>:]+)\s*>}

      # The attributes of a start tag without any.
      NO_ATTRIBUTES = {}.freeze

      # A comment, a processing instruction such as the XML declaration, and a CDATA section, with its text.
      COMMENT     = /<!--.*?-->/m
      INSTRUCTION = /<\?.*?\?>/m
      CDATA       = /<!\[CDATA\[(.*?)\]\]>/m

      # The local name of an extension list, which is skipped, see the class.
      EXTENSION_LIST = "extLst"

      # The start of a document type declaration.
      DOCTYPE = /<!DOCTYPE/i

      # The text up to the next tag.
      TEXT = /[^<]+/

      # The entities of XML and character references.
      ENTITY = /&(?:(amp|lt|gt|quot|apos)|#([0-9]+)|#x(\h+));/

      ENTITIES = {"amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'"}.freeze

      UTF8_BOM  = "\xEF\xBB\xBF".b.freeze
      UTF16_BOM = ["\xFF\xFE".b.freeze, "\xFE\xFF".b.freeze].freeze

      # Scans the XML of the supplied part, see .new.
      def self.scan(io, handler, part_name, display_name)
        new(io, handler, part_name, display_name).scan
      end

      # Returns [String] the text with the entities of XML and character references decoded, see the class.
      def self.decode(text)
        text = text.gsub(/\r\n?/, "\n") if text.include?("\r")
        return text unless text.include?("&")

        text.gsub(ENTITY) do |match|
          if ::Regexp.last_match(1)
            ENTITIES[::Regexp.last_match(1)]
          else
            code = ::Regexp.last_match(2) ? ::Regexp.last_match(2).to_i : ::Regexp.last_match(3).to_i(16)
            begin
              code.chr(Encoding::UTF_8)
            rescue RangeError
              match
            end
          end
        end
      end

      # Parameters:
      #   io: [#read]
      #     The XML of the part, which is read in chunks to its end.
      #   handler: [Object]
      #     Receives the events of the XML, see the class.
      #   part_name: [String]
      #     The name of the part within the workbook, such as `xl/worksheets/sheet1.xml`, which a failure names.
      #   display_name: [String]
      #     The name of the workbook, which a failure names.
      def initialize(io, handler, part_name, display_name)
        @io           = io
        @handler      = handler
        @part_name    = part_name
        @display_name = display_name
        @eof          = false
        @skipped      = 0
      end

      # Reads the whole part, calling the handler with each of its events.
      #
      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` for XML that is not well
      # formed, or that declares a document type, see the class.
      def scan
        scanner = StringScanner.new(first_chunk)
        handler = @handler
        until scanner.eos? && @eof
          if scanner.eos?
            refill(scanner)
          elsif scanner.string.getbyte(scanner.pos) == 60 # <
            next if read_markup(scanner, handler)

            fail("a tag that is not well formed") if @eof
            fail("a tag of more than #{LONGEST_TAG} bytes") if scanner.rest_size > LONGEST_TAG

            refill(scanner)
          else
            read_text(scanner, handler)
          end
        end
        nil
      end

      private

      # Reads the markup at the position of the scanner, and returns whether it is whole, otherwise the scanner has not
      # moved, and needs more of the part.
      #
      # The names of elements and attributes are binary text, rather than UTF-8, since that of the elements and the
      # attributes that are read is ASCII, which compares, and hashes, the same in either.
      def read_markup(scanner, handler)
        start = scanner.pos
        if scanner.string.getbyte(start + 1) == 47 # /
          return false unless scanner.scan(END_TAG)

          name = scanner[1]
          handler.end_element(name) unless skip_end?(name)
          true
        elsif scanner.scan(START_TAG)
          start_tag?(scanner, handler, start)
        elsif scanner.scan(COMMENT) || scanner.scan(INSTRUCTION)
          true
        elsif scanner.scan(CDATA)
          text = utf8(scanner[1])
          handler.text(text.include?("\r") ? text.gsub(/\r\n?/, "\n") : text) unless text.empty? || @skipped.positive?
          true
        elsif scanner.match?(DOCTYPE)
          fail("a document type declaration, which a workbook never holds")
        else
          false
        end
      end

      # Reads the attributes and the end of a start tag, whose name the scanner has read, and returns whether the tag is
      # whole, otherwise the scanner is moved back to its start.
      def start_tag?(scanner, handler, start)
        name       = scanner[1]
        attributes = nil
        (attributes ||= {})[scanner[1]] = attribute(scanner[2] || scanner[3]) while scanner.scan(ATTRIBUTE)
        unless scanner.scan(START_TAG_END)
          scanner.pos = start
          return false
        end

        empty = !scanner[1].empty?
        return true if skip_start?(name, !empty)

        handler.start_element(name, attributes || NO_ATTRIBUTES)
        handler.end_element(name) if empty
        true
      end

      # Reads the text up to the next tag. At the end of the chunk, it holds back a part of an entity or a CR, which the
      # next chunk can complete, rather than read the chunk again.
      def read_text(scanner, handler)
        text = scanner.scan(TEXT)
        if scanner.eos? && !@eof
          held = held_back(text)
          if held.positive?
            scanner.unscan
            return refill(scanner) if held == text.bytesize

            scanner.pos += text.bytesize - held
            text = text.byteslice(0, text.bytesize - held)
          end
        end
        handler.text(self.class.decode(utf8(text))) unless @skipped.positive?
      end

      # Returns [true|false] whether the start tag of the name is skipped, within an extension list, see the class,
      # counting the extension lists that it is within, unless the element closes itself.
      def skip_start?(name, opens)
        return @skipped.positive? unless name == EXTENSION_LIST

        @skipped += 1 if opens
        true
      end

      # Returns [true|false] whether the end tag of the name is skipped, within an extension list, see the class.
      def skip_end?(name)
        return false unless @skipped.positive?

        @skipped -= 1 if name == EXTENSION_LIST
        true
      end

      # Returns [Integer] the bytes at the end of the text that may continue in the next chunk: from an `&` without its
      # `;`, or a trailing CR, which may be the start of a CR LF.
      def held_back(text)
        amp = text.rindex("&")
        return text.bytesize - amp if amp && !text.index(";", amp)

        text.end_with?("\r") ? 1 : 0
      end

      # Returns [String] the value of an attribute, decoded, with each line break and tab a space, as XML normalizes the
      # value of an attribute, while a character reference of one is kept.
      def attribute(value)
        value = utf8(value)
        value = value.gsub(/\r\n?|[\t\n]/, " ") if value.match?(/[\t\n\r]/)
        value.include?("&") ? self.class.decode(value) : value
      end

      def first_chunk
        chunk = read_chunk || "".b
        fail("a UTF-16 byte order mark, rather than UTF-8 text") if UTF16_BOM.any? { |bom| chunk.start_with?(bom) }

        chunk.start_with?(UTF8_BOM) ? chunk.byteslice(3..) : chunk
      end

      # Appends the next chunk of the part to the rest of the scanner.
      def refill(scanner)
        chunk = read_chunk
        rest  = scanner.rest
        scanner.string = chunk ? rest << chunk : rest
      end

      def read_chunk
        return if @eof

        chunk = @io.read(CHUNK_SIZE)
        if chunk.nil? || chunk.empty?
          @eof = true
          return
        end
        chunk.force_encoding(Encoding::BINARY)
      end

      def utf8(text)
        text.force_encoding(Encoding::UTF_8)
      end

      def fail(reason)
        raise(Zip::Reader.failure(Errors::Corrupt,
                                  "The part #{@part_name.inspect} of the spreadsheet #{@display_name} holds #{reason}",
                                  @display_name))
      end
    end
  end
end
