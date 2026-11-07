# frozen_string_literal: true

module IOStreams
  module Xlsx
    # A workbook of `xlsxtream` that also writes cells of a time of day, of Excel's built-in time format `h:mm:ss`,
    # which `xlsxtream` does not write, since its styles are only a date and a date and time: a time of day is written
    # to it as a `Time` on Excel's first day, 1899-12-30, see `IOStreams::Xlsx::RowsWriter`, which `xlsxtream` writes as
    # a cell of a date and time whose number, its days, is less than 1, which no other cell of a date and time is, since
    # the rows writer writes a date and time before 1899-12-31 as its text, so that this workbook writes it as a cell of
    # a time of day instead, see `StyledParts#<<`, and adds that style to the styles of the workbook, see #write_styles,
    # so that `IOStreams::Xlsx::Cells` reads it back as a time of day. `IOStreams::Xlsx::Writer` writes with it only when
    # a column holds times of day, and otherwise with the workbook of `xlsxtream` itself.
    #
    # It writes the private parts of `xlsxtream`, its writer and its styles, so it raises `IOStreams::Errors::Error` for
    # a version of `xlsxtream` that does not write them as this workbook expects, see .check, rather than write a
    # workbook whose cells are not of their styles.
    class Workbook < ::Xlsxtream::Workbook
      # The versions of `xlsxtream` whose writer and styles this workbook knows: 2.x names its writer otherwise.
      VERSIONS = [">= 3.0", "< 4"].freeze

      # The style of a time of day, after the styles of `xlsxtream`: none, a date and a date and time.
      TIME_OF_DAY_STYLE = 3

      # The cell format of a time of day, Excel's built-in number format 21, `h:mm:ss`, see `IOStreams::Xlsx::Cells`.
      TIME_OF_DAY_FORMAT = %(<xf numFmtId="21" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>)

      # The styles of the cells of `xlsxtream`, after which the style of a time of day is added.
      CELL_STYLES = '<cellXfs count="3">'

      # The end of the styles of the cells.
      CELL_STYLES_END = "</cellXfs>"

      # The first day of Excel, whose time of day is the number of a cell of a time of day.
      FIRST_DAY = [1899, 12, 30].freeze

      # Raises `IOStreams::Errors::Error` unless the version of `xlsxtream` writes its styles and the cells of a date
      # and time as this workbook expects, see .problem, which is found once for each process, as the class is loaded,
      # see the end of the class, before anything is written, so that an existing file is not replaced, see
      # `IOStreams::Xlsx::Writer.check`.
      def self.check
        raise(IOStreams::Errors::Error, @problem) if @problem
      end

      # Returns [String|nil] why this workbook cannot write the styles of the version of `xlsxtream` that is loaded, or
      # nil when it can: a version other than VERSIONS, a style of a date and time other than 2, or styles that the
      # workbook of `xlsxtream` itself does not write, to its writer, with the cells of CELL_STYLES, see .written_styles.
      def self.problem
        version = ::Xlsxtream::VERSION
        unless Gem::Requirement.new(*VERSIONS).satisfied_by?(Gem::Version.new(version))
          return "xlsxtream #{version} is not a version whose styles IOStreams adds the style of a time of day to, " \
                 "which needs xlsxtream #{VERSIONS.join(', ')}"
        end
        parts = written_styles if ::Xlsxtream::Row::TIME_STYLE == 2
        return if parts&.any? { |xml| xml.include?(CELL_STYLES) && xml.include?(CELL_STYLES_END) }

        "xlsxtream #{version} no longer writes the styles of its cells as IOStreams adds the style of a time of day to them"
      end

      # Returns [Array<String>|nil] each part of XML of the styles that the workbook of `xlsxtream` itself writes to its
      # writer, `@writer`, with its options, `@options`, or nil when it does not write them so, such as a version that
      # names its writer otherwise, or has no `#write_styles`.
      def self.written_styles
        parts    = StyledParts::Recorder.new
        workbook = ::Xlsxtream::Workbook.allocate
        workbook.instance_variable_set(:@writer, parts)
        workbook.instance_variable_set(:@options, {})
        workbook.send(:write_styles)
        parts.xml
      rescue NameError, ArgumentError
        nil
      end
      private_class_method :problem, :written_styles

      # Returns [Time] the time on Excel's first day of the clock of the supplied time, see the class.
      def self.time_of_day(time)
        Time.utc(*FIRST_DAY, time.hour, time.min, time.sec + time.subsec)
      end

      def initialize(output, options = {})
        self.class.check
        super
        @writer = StyledParts.new(@writer)
      end

      private

      # Writes the styles of `xlsxtream`, with the style of a time of day after them, see TIME_OF_DAY_STYLE.
      def write_styles
        @writer.styles = true
        super
      ensure
        @writer.styles = false
      end

      # The writer of the parts of the workbook, which writes a cell of a date and time whose number is less than 1 as
      # a cell of a time of day, and adds its style to the styles, see the class.
      class StyledParts
        # The style and value of a cell of a date and time whose number is less than 1, a time of day, see the class:
        # `0.` and its fraction, such as `0.395833` for 09:30, or a number below 0.0001, which Ruby writes with an
        # exponent, such as `1.1574074074074073e-05` for one second after midnight.
        TIME_OF_DAY = /(?<= s=")#{::Xlsxtream::Row::TIME_STYLE}(?="><v>(?:0\.|[1-9](?:\.\d+)?[eE]-))/
        # The style of a cell of a time of day.
        TIME_OF_DAY_CELL = TIME_OF_DAY_STYLE.to_s.freeze
        # The style of a cell of a date and time, which a part of XML must hold for it to hold a time of day.
        DATE_TIME_CELL = %( s="#{::Xlsxtream::Row::TIME_STYLE}"><v>).freeze

        # Whether the part being written is the styles of the workbook.
        attr_writer :styles

        def initialize(writer)
          @writer = writer
          @styles = false
        end

        def add_file(...)
          @writer.add_file(...)
        end

        def close
          @writer.close
        end

        # Writes the XML of a part, with the style of a time of day added to the styles, see Workbook::CELL_STYLES, and
        # each cell of a time of day of that style.
        def <<(xml)
          @writer << (@styles ? with_time_of_day_style(xml) : time_of_day_cells(xml))
        end

        # The writer that the workbook of `xlsxtream` writes its styles to, which keeps the XML of each part, see
        # `Workbook.written_styles`.
        class Recorder
          # Returns [Array<String>] the XML of each part written.
          attr_reader :xml

          def initialize
            @xml = []
          end

          def add_file(*)
          end

          def <<(xml)
            @xml << xml
            self
          end
        end

        private

        # Returns [String] the XML with each cell of a time of day of its style, or the XML itself without one.
        def time_of_day_cells(xml)
          xml.include?(DATE_TIME_CELL) ? xml.gsub(TIME_OF_DAY, TIME_OF_DAY_CELL) : xml
        end

        # Returns [String] the XML of the styles of the workbook with the style of a time of day after the others, which
        # `Workbook.check` found that `xlsxtream` writes in one part.
        def with_time_of_day_style(xml)
          return xml unless xml.include?(CELL_STYLES)

          xml.sub(CELL_STYLES, '<cellXfs count="4">').sub(CELL_STYLES_END, "#{TIME_OF_DAY_FORMAT}#{CELL_STYLES_END}")
        end
      end
      private_constant :StyledParts

      # The problem, see .check, found as the class is loaded, which Ruby does in the main Ractor, since a class-level
      # cache could only be set there, see `IOStreams::Utils.main_ractor?`.
      @problem = problem&.freeze
    end
  end
end
