# frozen_string_literal: true

module IOStreams
  module Xlsx
    # The shared strings of a workbook that IOStreams writes: each distinct text of its cells, once, by its index, which
    # a cell of the text names, so that a workbook whose text repeats is smaller, while every distinct text is held in
    # memory until the workbook is complete, when it writes the part that holds them, `xl/sharedStrings.xml`.
    class SharedStringTable
      # The part, by its name within the workbook.
      PART = "xl/sharedStrings.xml"

      # The size of XML that is collected before it is written to the part.
      BUFFER_SIZE = 65_536

      def initialize
        @indexes    = {}
        @references = 0
      end

      # Returns [Integer] the index of the text, which `IOStreams::Xlsx::Text.encode` escaped, adding it when it is new.
      def index(text)
        @references += 1
        @indexes[text] ||= @indexes.size
      end

      # Returns [true|false] whether no text was added, so that the workbook has no part of shared strings.
      def empty?
        @indexes.empty?
      end

      # Writes the XML of the part to the output, which responds to `#<<`, in parts of about BUFFER_SIZE, since each
      # write compresses what it writes.
      def write(output)
        xml = +%(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>)
        xml << %(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="#{@references}" )
        xml << %(uniqueCount="#{@indexes.size}">)
        @indexes.each_key do |text|
          xml << "<si>" << Text.element(text) << "</si>"
          next if xml.bytesize < BUFFER_SIZE

          output << xml
          xml = +""
        end
        output << (xml << "</sst>")
      end
    end
  end
end
