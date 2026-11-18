# frozen_string_literal: true

module IOStreams
  # Zip compression: reads a file within a zip file, and writes a zip file that contains one file.
  module Zip
    extend StreamFormat

    autoload :Reader, "io_streams/zip/reader"
    autoload :Writer, "io_streams/zip/writer"

    # Returns [Class] the class that reads a zip file.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes a zip file.
    def self.writer_class
      Writer
    end

    # Returns [true|false] whether data in this format is compressed.
    def self.compressed?
      true
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      false
    end

    # Returns [String] the supplied name of a file within a zip file in UTF-8, the encoding that a zip file names its
    # files in, since `zip_kit` writes the bytes of a name as UTF-8, or nil when it is not valid in its encoding, or
    # holds a character that UTF-8 does not have, or is in an encoding that Ruby cannot convert to UTF-8. A binary name
    # is read as UTF-8.
    def self.utf8_entry_name(name)
      convert_entry_name(name)
    rescue EncodingError
      nil
    end

    # Returns [String] why the supplied name cannot name a file within a zip file, see .utf8_entry_name, such as
    # "it is not valid UTF-8", or nil when it can.
    def self.entry_name_problem(name)
      convert_entry_name(name)
      nil
    rescue Encoding::ConverterNotFoundError
      "Ruby cannot convert #{name.encoding} to UTF-8"
    rescue Encoding::UndefinedConversionError
      "it holds a character that UTF-8 does not have"
    rescue EncodingError
      "it is not valid #{name.encoding == Encoding::BINARY ? Encoding::UTF_8 : name.encoding}"
    end

    # Returns [String] the supplied name in UTF-8, reading a binary name as UTF-8, and raises the `EncodingError` of
    # the conversion when it cannot be converted, and `Encoding::InvalidByteSequenceError` before converting a name
    # that is not valid in its encoding, since converting UTF-8 to UTF-8 does not check it.
    def self.convert_entry_name(name)
      text = name.encoding == Encoding::BINARY ? name.dup.force_encoding(Encoding::UTF_8) : name
      raise(Encoding::InvalidByteSequenceError) unless text.valid_encoding?

      text.encode(Encoding::UTF_8)
    end
    private_class_method :convert_entry_name

    # Returns [Array] the entry of the file within a zip file of the supplied name, its index, and whether it has the
    # name exactly, from the supplied entries of its files, an Enumerable of each entry with the bytes of its name, as
    # the zip file holds them, or nil when none has the name. Without a name, it is the first file.
    #
    # The file whose name is the name in UTF-8, see .utf8_entry_name, is read, the name that IOStreams writes, so that
    # a name that is not ASCII finds the file whether the library that reads it gives its name as UTF-8 or as its bytes,
    # as rubyzip does, and a name in another encoding finds it too. When no file has it, the first file that has the
    # name by the bytes that it was given is read, such as a name in Windows-1252, then the first file that has its
    # bytes in ISO-8859-1, see .latin1_bytes, as some other programs write the name, so that a file that another program
    # named so is never read in place of the file of the name. It stops at the file of the name, so that a reader that
    # streams the files does not read past it, while it reads every file before it gives one that it found by other
    # bytes, which the reader no longer holds. A name that is not a String, such as a Symbol, is read by its `to_s`, as
    # rubyzip reads it.
    def self.choose_entry(name, entries)
      exact, *others = name.nil? ? [nil] : entry_name_bytes(name)
      found          = []
      entries.each_with_index do |(entry, held_name), index|
        bytes = held_name.b
        return [entry, index, true] if exact.nil? || bytes == exact

        rank = others.index(bytes)
        found[rank] ||= [entry, index, false] if rank
      end
      found.compact.first
    end

    # Returns [Array<String>] the bytes of the supplied name of a file within a zip file, see .choose_entry: first the
    # name in UTF-8, then those of other names that it may have been written as, in order: its own bytes, and its bytes
    # in ISO-8859-1, each only when it differs from those before it. A name that UTF-8 cannot hold has only its own bytes.
    def self.entry_name_bytes(name)
      text = name.to_s
      utf8 = utf8_entry_name(text)
      return [text.b] unless utf8

      [utf8.b, text.b, latin1_bytes(utf8)].compact.uniq
    end
    private_class_method :entry_name_bytes

    # Returns [String|nil] the bytes of the supplied name in ISO-8859-1, or nil when ISO-8859-1 does not hold a
    # character of it.
    def self.latin1_bytes(name)
      name.encode(Encoding::ISO_8859_1).b
    rescue EncodingError
      nil
    end
    private_class_method :latin1_bytes
  end
end
