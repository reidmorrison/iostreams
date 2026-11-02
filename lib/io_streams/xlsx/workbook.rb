# frozen_string_literal: true

module IOStreams
  module Xlsx
    # A workbook of `xlsxtream` that also writes cells of a time of day, of Excel's built-in time format `h:mm:ss`,
    # which `xlsxtream` does not write, since its styles are only a date and a date and time: a time of day is written
    # to it as a `Time` on Excel's first day, 1899-12-30, see `IOStreams::Xlsx::RowsWriter`, which `xlsxtream` writes as
    # a cell of a date and time whose number, its days, is less than 1, which no date of Excel is, so that this
    # workbook writes it as a cell of a time of day instead, see `Cells#<<`, and adds that style to the styles of the
    # workbook, see #write_styles, so that `IOStreams::Xlsx::Cells` reads it back as a time of day.
    #
    # Raises `IOStreams::Errors::Error` when the version of `xlsxtream` no longer writes them as this workbook expects,
    # see .check, rather than write a workbook whose cells are not of their styles.
    class Workbook < ::Xlsxtream::Workbook
      # The style of a time of day, after the styles of `xlsxtream`: none, a date and a date and time.
      TIME_OF_DAY_STYLE = 3

      # The cell format of a time of day, Excel's built-in number format 21, `h:mm:ss`, see `IOStreams::Xlsx::Cells`.
      TIME_OF_DAY_FORMAT = %(<xf numFmtId="21" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>)

      # The first day of Excel, whose time of day is the number of a cell of a time of day.
      FIRST_DAY = [1899, 12, 30].freeze

      # Raises `IOStreams::Errors::Error` unless the version of `xlsxtream` writes its styles and the cells of a date
      # and time as this workbook expects.
      def self.check
        return if ::Xlsxtream::Row::TIME_STYLE == 2 && private_method_defined?(:write_styles)

        raise(IOStreams::Errors::Error, "xlsxtream #{::Xlsxtream::VERSION} no longer writes the styles of its cells as " \
                                        "IOStreams adds the style of a time of day to them")
      end

      # Returns [Time] the time on Excel's first day of the clock of the supplied time, see the class.
      def self.time_of_day(time)
        Time.utc(*FIRST_DAY, time.hour, time.min, time.sec + time.subsec)
      end

      def initialize(output, options = {})
        self.class.check
        super
        @writer = Cells.new(@writer)
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
      class Cells
        # A cell of a date and time whose number is less than 1, a time of day, see the class.
        TIME_OF_DAY = %( s="#{::Xlsxtream::Row::TIME_STYLE}"><v>0.).freeze
        # The cell of that time of day.
        TIME_OF_DAY_CELL = %( s="#{TIME_OF_DAY_STYLE}"><v>0.).freeze
        # The styles of the cells of `xlsxtream`.
        CELL_STYLES = '<cellXfs count="3">'

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

        # Writes the XML of a part, with the style of a time of day added to the styles, and each cell of a time of day
        # of that style.
        #
        # Raises `IOStreams::Errors::Error` for styles that are not those of the version of `xlsxtream` that it knows.
        def <<(xml)
          @writer << (@styles ? with_time_of_day_style(xml) : time_of_day_cells(xml))
        end

        private

        # Returns [String] the XML with each cell of a time of day of its style, or the XML itself without one.
        def time_of_day_cells(xml)
          xml.include?(TIME_OF_DAY) ? xml.gsub(TIME_OF_DAY, TIME_OF_DAY_CELL) : xml
        end

        # Returns [String] the XML of the styles of the workbook with the style of a time of day after the others.
        def with_time_of_day_style(xml)
          return xml unless xml.include?("<cellXfs")
          unless xml.include?(CELL_STYLES) && xml.include?("</cellXfs>")
            raise(IOStreams::Errors::Error, "xlsxtream #{::Xlsxtream::VERSION} writes styles that IOStreams cannot add " \
                                            "the style of a time of day to")
          end

          xml.sub(CELL_STYLES, '<cellXfs count="4">').sub("</cellXfs>", "#{TIME_OF_DAY_FORMAT}</cellXfs>")
        end
      end
      private_constant :Cells
    end
  end
end
