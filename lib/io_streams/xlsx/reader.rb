# frozen_string_literal: true

require "csv"
require "zlib"

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Returns [Array<Symbol>] the arguments of the rows that a stream reads, see .file, which are not options.
      def self.argument_names
        %i[rows decimals strings missing times text]
      end

      # Returns [Array<Symbol>] the options of the writer that reading raises for: `sheet_name`, since a caller could
      # expect it to read that worksheet, which it does not, since it reads the first. The other options of the writer
      # are ignored, since the workbook records them.
      def self.unsupported_option_names
        %i[sheet_name]
      end

      # Returns [Module] `IOStreams::Errors::Corrupt` for an exception that rubyzip raises for a file that is not a zip
      # file, `Zip::Error`, see `IOStreams::Reader.failure_kind`. IOStreams raises its own, tagged the same way, for a
      # zip file that is not a spreadsheet, see `IOStreams::Xlsx::Package`, and for XML that is not well formed, see
      # `IOStreams::Xlsx::XmlScanner`.
      def self.failure_kind(exception)
        Errors::Corrupt if defined?(::Zip::Error) && exception.is_a?(::Zip::Error)
      end

      # Its failures name the spreadsheet that is read, rather than the temp file that a spreadsheet that is not a local
      # file is copied into, see `IOStreams::Reader.takes_display_name?`.
      def self.takes_display_name?
        true
      end

      # Convert a xlsx, or xlsm file into CSV format, or with `rows: true`, see `IOStreams::Xlsx.rows_format`, yield the
      # rows of its first worksheet, each an Array of the value of each of its cells, typed by Excel, see
      # `IOStreams::Xlsx::Cells`.
      #
      # Raises the exception of rubyzip, tagged as `IOStreams::Errors::Corrupt`, for a file that is not a zip file, see
      # .failure_kind, and `IOStreams::Errors::StreamFailure`, tagged the same way, for a zip file that is not a
      # spreadsheet, and `IOStreams::Errors::StreamFailure`, tagged the same way, for a part of the spreadsheet that is
      # damaged, see .verify, naming the spreadsheet by its `display_name`, see .takes_display_name?, otherwise by the name
      # of the local file.
      def self.file(file_name, display_name: nil, rows: false, decimals: nil, strings: nil, missing: nil, times: nil,
                    text: false, &block)
        Utils.load_soft_dependency("rubyzip", "Xlsx", "zip") unless defined?(::Zip::File)
        name = display_name || file_name
        verify(file_name, name)
        arguments = {decimals: decimals, strings: strings, missing: missing, times: times, text: text}
        return yield(Rows.new(file_name, name, **arguments)) if rows

        # Stream into a temp file as csv
        Utils.private_temp_file("iostreams_csv", purpose: "the rows of the spreadsheet as CSV") do |temp_file_name|
          ::File.open(temp_file_name, "wb") do |io|
            tag_failure(name) { each_text_row(file_name, name) { |row| io << row.to_csv } }
          end
          ::File.open(temp_file_name, "rb", &block)
        end
      end

      # Raises unless each part of the spreadsheet has the size and the CRC32 that the spreadsheet records for it, see
      # `IOStreams::Zip::Reader.check_entry`, since rubyzip, which reads it, checks neither, so that a damaged part read
      # wrong values without an error. Reads each part once more, before its rows are read.
      def self.verify(file_name, name)
        Zip::Reader.open_zip(file_name, name).each do |entry|
          next unless entry.file?

          size = 0
          crc  = Zlib.crc32
          tag_failure(name) do
            entry.get_input_stream do |input|
              while (chunk = input.read(65_536))
                size += chunk.bytesize
                crc   = Zlib.crc32(chunk, crc)
              end
            end
          end
          Zip::Reader.check_entry(entry, size, crc, name)
        end
      end

      # Yields [IOStreams::Xlsx::Book] the workbook of the spreadsheet file, which it closes once the block returns.
      def self.open_book(file_name, display_name)
        zip = Zip::Reader.open_zip(file_name, display_name)
        book = tag_failure(display_name) { Book.new(Package.new(zip, display_name)) }
        yield(book)
      ensure
        zip&.close
      end

      # Yields [Array] each row of the first worksheet of the spreadsheet file, with the text of each cell, as
      # `IOStreams::Xlsx::Cells.text` gives it, the same in every process, so that the lines and the rows of the
      # workbook agree on which cells hold a date or a time, or nil for an empty cell.
      def self.each_text_row(file_name, display_name, &block)
        open_book(file_name, display_name) do |book|
          formats = book.number_formats
          options = {shared_strings: book.shared_strings, base_date: book.base_date}
          book.each_row(->(text, type, style) { Cells.text(text, type, formats[style], options) }, &block)
        end
      end

      # The rows of the first worksheet of a workbook, each an Array of the value of each of its cells, typed by Excel's own
      # cell type and number format, see `IOStreams::Xlsx::Cells`.
      class Rows
        include Enumerable

        # Parameters:
        #   decimals: [#call|nil]
        #     Returns the positions of the values of the rows that keep the digits of their numbers, such as those of a
        #     `number` field, rather than the Float that Excel holds, so that each number of the column is the BigDecimal
        #     of the digits that Excel displays, such as `0.3` for the Float `0.30000000000000004`, or nil until they are
        #     known, once the header row is read, so it is called before each row until it returns them. The stream
        #     supplies it for its schema or contract, which the reader never sees, as JSON keeps the digits of its numbers.
        #     Default: nil, every number is a Float.
        #
        #   strings: [#call|nil]
        #     Returns the positions of the values of the rows that are text, such as those of a `string` field, so that
        #     each number of the column is the text of the number that the cell holds, to the digits that Excel displays,
        #     see `decimals`, such as `2134` for the zip code that Excel holds as the Float `2134.0`, or nil until they
        #     are known, as for `decimals`.
        #     Default: nil, every number is a Float.
        #
        #   missing: [#call|nil]
        #     Returns the positions of the values of the rows whose text can be a missing value other than empty text,
        #     such as "-99", with what answers whether the text of a cell is one of them, `#call(text)`, so that such a
        #     cell is that text, whatever Excel holds, such as the number -99, which its field reads as a missing value,
        #     as Frictionless compares the text of a value with its missing values before it reads its type, or nil until
        #     they are known, as for `decimals`. The text of a cell is the text that the CSV text of the worksheet holds,
        #     see `IOStreams::Xlsx::Cells.text`. So a row whose every cell is a missing value is not blank, and is read as
        #     a record whose every value is missing, as its CSV text is.
        #     Default: nil, no cell is compared.
        #
        #   times: [#call|nil]
        #     Returns the positions of the values of the rows whose field reads the cell of a time of day otherwise than as
        #     the Time that it holds, with how, see `IOStreams::Schema::Field#time_cell`: `:clock`, as the text of its
        #     clock, such as `09:30:00`, as the CSV text of the cell holds it, see `IOStreams::Xlsx::Cells.clock`, such as
        #     a `string` field, which reads that text, or a `date` or `datetime` field, which raises for it, as it does for
        #     the CSV text, or `:length`, as the ISO 8601 text of its length, which a `duration` field reads, also of a
        #     cell of an elapsed time of a day or more, see `IOStreams::Xlsx::Cells.length`, or nil until they are known,
        #     as for `decimals`.
        #     Default: nil, every time of day is a Time.
        #
        #   text: [true|false]
        #     Whether each value is the text of its cell, as the CSV text of the worksheet holds it, see
        #     `IOStreams::Xlsx::Cells.text`, the default text of the value of the cell, rather than that value, such as
        #     the slices of a spreadsheet read without a schema, so that a schema reads them as it reads the slices of the
        #     CSV text, see `IOStreams::Stream#open_slice_rows`.
        #     Default: false
        def initialize(file_name, display_name, decimals: nil, strings: nil, missing: nil, times: nil, text: false)
          @file_name    = file_name
          @display_name = display_name
          @decimals     = decimals
          @strings      = strings
          @missing      = missing
          @times        = times
          @text         = text
        end

        # Yields [Array] each row, as an Array of the values of its cells, from the first, the header row of a worksheet
        # with one, see `IOStreams::Tabular`, and the empty cells before a cell that holds a value as nil.
        #
        # Raises `IOStreams::Errors::StreamFailure` tagged as `IOStreams::Errors::Corrupt` for a worksheet that it
        # cannot read, see `IOStreams::Xlsx::Reader.file`.
        def each
          return enum_for(:each) unless block_given?

          positions = {}
          Reader.open_book(@file_name, @display_name) do |book|
            times = {}.compare_by_identity
            # Reads the styles and the shared strings of the workbook.
            convert = Reader.tag_failure(@display_name) { converter(book, times) }
            each_row(book, convert) do |row|
              read_row(row, positions, times)
              yield(row)
            end
          end
        end

        private

        # Reads the values of the row as the fields of their positions read them, see #initialize, which are known once
        # the header row is read, and kept in the supplied Hash, and forgets the time cells of the row, see #converter.
        def read_row(row, positions, times)
          read_cells(row, known(positions, :missing, @missing), times) if @missing
          forms = known(positions, :times, @times)
          read_times(row, forms, times) if forms && !times.empty?
          known(positions, :decimals, @decimals)&.each { |index| row[index] = displayed(row[index]) }
          known(positions, :strings, @strings)&.each { |index| row[index] = displayed_text(row[index]) }
          row.each { |value| times.delete(value) } unless times.empty?
        end

        # Returns the positions of the supplied kind, which the source returns once they are known, see #initialize,
        # kept in the Hash, or nil without a source, or until they are known.
        def known(positions, kind, source)
          positions[kind] ||= source&.call
        end

        # Returns [#call] the converter of the text, type and style of each cell of the workbook to its value, typed by
        # Excel's own cell type and number format, see `IOStreams::Xlsx::Cells.value`, which fills the supplied Hash
        # with the TimeCell of each cell of a time format, by the Time that the cell holds, itself, rather than its
        # value, since a cell of a date and time can hold the same time: the text of its clock, see
        # `IOStreams::Xlsx::Cells.clock`, and of its length, see `IOStreams::Xlsx::Cells.length`, which a field that
        # reads it otherwise than as the Time reads, see `times` in #initialize, only when there are such fields.
        #
        # When the text of a cell can be a missing value, see `missing` in #initialize, each cell is its value with its
        # text, a Cell, until #read_cells reads the row.
        def converter(book, times)
          formats = book.number_formats
          options = {shared_strings: book.shared_strings, base_date: book.base_date}
          lambda do |text, type, style|
            next Cells.text(text, type, formats[style], options) if @text

            value  = Cells.value(text, type, formats[style], options)
            length = @times && Cells.length(text, type, formats[style])
            times[value] = TimeCell.new(Cells.clock(text, type, formats[style]), length) if length
            @missing ? Cell.new(value, Cells.text(text, type, formats[style], options)) : value
          end
        end

        # The text of a cell of a time format, see #converter: its clock, below a day, otherwise nil, and its length.
        TimeCell = Data.define(:clock, :length)

        # The value of a cell with its text, see `IOStreams::Xlsx::Cells.text`, which a missing value is compared with,
        # see `missing` in #initialize, until #read_cells reads the row.
        Cell = Struct.new(:value, :text)

        # Replaces each cell of the row with its value, or its text when that is a missing value of the field of its
        # position, see `missing` in #initialize, which the field reads as missing, forgetting the time cell of a time
        # that is missing, see #converter.
        def read_cells(row, missing, times)
          row.each_with_index do |cell, index|
            next unless cell.is_a?(Cell)

            missing_value = missing&.[](index)
            if missing_value&.call(cell.text)
              times.delete(cell.value)
              row[index] = cell.text
            else
              row[index] = cell.value
            end
          end
        end

        # Replaces the Time of each cell of a time format of the row whose field reads it otherwise, see `times` in
        # #initialize, with the text of its clock or of its length, as the form of the field says, and forgets it, see
        # #type_cells. A cell of a day or more has no clock, so that a field that reads the clock reads its Time.
        def read_times(row, forms, times)
          forms.each_pair do |index, form|
            cell = times.delete(row[index])
            text = form == :length ? cell&.length : cell&.clock
            row[index] = text if text
          end
        end

        # Returns [BigDecimal|Object] the number of a Float that the cell holds, to the digits that Excel displays, see
        # `IOStreams::Xlsx::Cells.displayed`, or any other value as it is.
        def displayed(value)
          value.is_a?(Float) && value.finite? ? Cells.displayed(value) : value
        end

        # Returns [String|Object] the text of the number of a Float that the cell holds, to the digits that Excel
        # displays, as the CSV text of the cell holds it, see `IOStreams::Xlsx::Cells.displayed_text`, such as "2134" for
        # `2134.0`, the clock of a cell of a date and time without an offset, such as "2026-01-02T09:30:00", as the CSV
        # text of the cell holds it, see `IOStreams::Xlsx::Cells.text`, or any other value as it is.
        def displayed_text(value)
          return Schema::Field.clock_text(value) if value.is_a?(Time)
          return value unless value.is_a?(Float) && value.finite?

          Cells.displayed_text(value)
        end

        # Yields the values of each row of the worksheet, tagging a failure of rubyzip as `.failure_kind` says, but not one
        # that the block raises, which is raised as it is, as the block is called while the worksheet is read.
        def each_row(book, converter)
          in_block = false
          book.each_row(converter) do |row|
            in_block = true
            yield(row)
            # Not reset in an ensure, which would clear it before the exception that the block raised reaches the rescue.
            in_block = false
          end
          nil
        rescue StandardError => e
          raise if in_block

          kind = Reader.failure_kind(e)
          raise(kind ? kind.tag(e, @display_name) : e)
        end
      end
    end
  end
end
