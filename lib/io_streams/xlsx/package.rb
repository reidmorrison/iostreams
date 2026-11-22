# frozen_string_literal: true

module IOStreams
  module Xlsx
    # The parts of a workbook, a zip file of XML parts that name each other by relationships, as the Open Packaging
    # Conventions describe: it finds a part by its name, without case, as they say, and the parts that a part relates to
    # by the type of their relationship, of either Transitional or Strict OOXML, rather than by the names that a
    # spreadsheet application usually gives them, such as `xl/workbook.xml`, which others need not use.
    class Package
      # The relationships part of the package itself, which names its main part, the workbook.
      ROOT_RELATIONSHIPS = "_rels/.rels"

      # The part of the workbook when the package does not name it, as Excel names it.
      DEFAULT_WORKBOOK = "xl/workbook.xml"

      # A relationship of a part: the last segment of its type, such as `worksheet`, which is the same in Transitional
      # and Strict OOXML, and the name of the part that it targets.
      Relationship = Data.define(:id, :type, :target)

      # The first bytes of a compound file, the format of a workbook of Excel 97-2003, `.xls`, and of a workbook that
      # Excel encrypts with a password, which holds the encrypted package within one, rather than a zip file.
      COMPOUND_FILE = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze

      # Returns [String] the name of the workbook, as failures name it.
      attr_reader :display_name

      # Parameters:
      #   zip: [Zip::File]
      #     The workbook, as rubyzip reads its list of parts.
      #   display_name: [String]
      #     The name of the workbook, which failures name.
      def initialize(zip, display_name)
        @display_name = display_name
        @entries      = {}
        zip.each do |entry|
          @entries[self.class.normalize(entry.name).downcase] ||= entry if entry.file?
        end
      end

      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` for a file that is a compound
      # file, see COMPOUND_FILE, rather than a package, saying what it is, since both are what a user of Excel most often
      # supplies in place of a workbook that IOStreams reads, while rubyzip would say only that it is not a zip file.
      #
      # Parameters:
      #   file_name: [String]
      #     The local file of the workbook.
      #   display_name: [String]
      #     The name of the workbook, which failures name.
      def self.check(file_name, display_name)
        return unless ::File.binread(file_name, COMPOUND_FILE.bytesize) == COMPOUND_FILE

        raise(Zip::Reader.failure(Errors::Corrupt, "The spreadsheet #{display_name} is a workbook of Excel 97-2003 " \
                                                   "(.xls), or one protected by a password, which IOStreams does not " \
                                                   "read: save it in Excel as an Excel Workbook (.xlsx) without a " \
                                                   "password", display_name))
      end

      # Returns [String] the name of a part as the package names it, without a leading `/`, with `/` between segments,
      # and its `.` and `..` segments resolved.
      def self.normalize(name)
        segments = []
        name.tr("\\", "/").split("/").each do |segment|
          case segment
          when "", "." then next
          when ".." then segments.pop
          else segments << segment
          end
        end
        segments.join("/")
      end

      # Returns [true|false] whether the package holds a part of the name, without case.
      def part?(name)
        @entries.key?(name.downcase)
      end

      # Yields [IO] the stream of the part of the name, which it closes once the block returns.
      #
      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` for a part that the package
      # does not hold.
      def open_part(name, &)
        entry = @entries[name.downcase] || raise(missing(name))
        entry.get_input_stream(&)
      end

      # Reads the XML of the part of the name with the handler, see `IOStreams::Xlsx::XmlScanner`.
      def scan(name, handler)
        open_part(name) { |io| XmlScanner.scan(io, handler, name, display_name) }
        handler
      end

      # Returns [String] the name of the main part of the package, the workbook.
      def workbook_part
        relationships("").find { |relationship| relationship.type == "officeDocument" }&.target || DEFAULT_WORKBOOK
      end

      # Returns [Array<Relationship>] the relationships of the part of the name, or of the package itself for "", in
      # order, other than those to an external resource, or none when it has no relationships part.
      def relationships(part_name)
        rels = relationships_part(part_name)
        return [] unless part?(rels)

        source = part_name.include?("/") ? part_name[0..part_name.rindex("/")] : ""
        scan(rels, Relationships.new(source)).relationships
      end

      # Returns [Exception] the failure for a part of the name that the package does not hold.
      def missing(name)
        Zip::Reader.failure(Errors::Corrupt, "The spreadsheet #{display_name} does not contain the part #{name.inspect}",
                            display_name)
      end

      private

      # Returns [String] the name of the relationships part of a part, such as `xl/_rels/workbook.xml.rels`.
      def relationships_part(part_name)
        return ROOT_RELATIONSHIPS if part_name.empty?

        slash = part_name.rindex("/")
        slash ? "#{part_name[0..slash]}_rels/#{part_name[(slash + 1)..]}.rels" : "_rels/#{part_name}.rels"
      end

      # Reads the relationships of a part, resolving each target against the folder of its source part, or against the
      # package for a target that starts with `/`.
      class Relationships
        attr_reader :relationships

        def initialize(source)
          @source        = source
          @relationships = []
        end

        def start_element(name, attributes)
          return unless name == "Relationship"
          return if attributes["TargetMode"]&.casecmp?("External")

          target = attributes["Target"]
          type   = attributes["Type"]
          return unless target && type

          target = "#{@source}#{target}" unless target.start_with?("/")
          @relationships << Relationship.new(attributes["Id"], type.split("/").last, Package.normalize(target))
        end

        def end_element(_name)
        end

        def text(_text)
        end
      end
    end
  end
end
