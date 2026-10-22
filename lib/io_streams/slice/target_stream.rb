# frozen_string_literal: true

module IOStreams
  class Slice
    # The stream of a store of slices, see `IOStreams::Slice::Target`, which `IOStreams.stream(target)` returns, so that
    # the lines, rows or records written to it, or copied to it from a file or a query, are written to the store in
    # slices of up to the number of rows that the store holds in each one, see `IOStreams::Slice::Target#slice_size`, as
    # `IOStreams::Stream#each(:slice)` reads them from a file:
    #
    #   IOStreams.stream(store).format(:csv).schema(schema).writer(:line) do |io|
    #     io << "name,age"
    #     io << "Jack,21"
    #   end
    #
    #   IOStreams.stream(store).schema(schema).copy_from("people.csv.gz", mode: :line)
    #
    # The rows are rendered as lines in the format of the stream, by its schema, as they would be written to a file, and
    # then collected into slices, see `IOStreams::Slice::Collector`, so that the header row is matched to the fields of
    # the schema, and raises `IOStreams::Errors::InvalidHeader` before the first slice is written to the store when they
    # do not match, and each slice carries it. The last slice is written once the block finishes, or leaves early, such
    # as with `break`, but not when it raises.
    #
    # A store holds slices rather than bytes, so the `:stream` mode, the streams and options of #stream and #option, an
    # encoding and #raw raise ArgumentError, see `IOStreams::Row::WithoutBytes`, as do a file name, since a store has
    # none, and a format whose rows are not lines, such as Parquet. It is only written, so #reader, #each and #read
    # raise ArgumentError too.
    class TargetStream < IOStreams::Stream
      include IOStreams::Row::WithoutBytes

      # The modes that write rows into slices, see #writer.
      MODES = %i[line array hash].freeze

      # Returns [Array<Symbol>] the options of each call that writes rows into slices, see #writer, which raises for any
      # other. The store decides the number of rows of each slice, see `IOStreams::Slice::Target#slice_size`.
      def self.option_names
        %i[validate]
      end

      # Parameters
      #   target: [IOStreams::Slice::Target]
      #     The store that each slice is written to.
      def initialize(target)
        unless target.is_a?(Target)
          raise(ArgumentError, "Not a target of slices: #{target.class.name}, include IOStreams::Slice::Target")
        end

        super
      end

      # Yields the writer of the supplied mode, whose lines, rows or records are written to the store in slices:
      #   :line   the lines of a file, such as its header row followed by its rows, as `IOStreams::Stream#writer(:line)`
      #           takes them. A line that holds a line ending is split into rows as reading the file back would split
      #           it, so that a line ending within a quoted value of CSV stays within its row, see
      #           `IOStreams::Line::Reader`, and a quoted value that is not closed raises
      #           `IOStreams::Errors::MalformedDataError`, with the number of the line that it starts on, once the text
      #           written after it exceeds the most that a line reader reads into one line, or when the block returns.
      #   :array  each row, see `IOStreams::Row::Writer`.
      #   :hash   each record, see `IOStreams::Record::Writer`.
      #
      # Each slice holds the number of rows that the store says, see `IOStreams::Slice::Target#slice_size`, apart from
      # the last, which holds the rows that are left.
      #
      # Parameters
      #   validate: [true|false]
      #     Whether to parse each row before it is added to its slice, so that a row that the format or the schema
      #     cannot read raises before the slice that holds it is written, see `IOStreams::Slice::Collector`.
      #     Default: false
      #
      # Returns the result of the block.
      #
      # Raises ArgumentError for any other mode, or option, or a slice size of the store that is not a positive Integer,
      # before the block is called.
      def writer(mode = :stream, **args, &block)
        require_block!(:writer, block)
        write_slices(mode, slice_options(mode, args), &block)
      end

      # Copies the lines, rows or records of the supplied source, such as a path, a stream or an Active Record query,
      # see `IOStreams::Stream#copy_from`, to the store in slices, see #writer, which takes the options of the copy, such
      # as `validate:`. Each slice holds whether the blank rows of the source are records, as those of a query are, see
      # `IOStreams::Slice#blank_rows?`. The lines of the `:line` mode are in the format of the source, which the slices
      # carry, unless the stream has a format of its own.
      #
      # Raises ArgumentError without a `mode:`, or with `convert: false`, since the store holds slices of rows rather
      # than bytes, or in the `:line` mode when the format of the stream is not that of the source, before the source
      # is opened.
      def copy_from(source, convert: true, mode: nil, **args)
        unless convert && MODES.include?(mode)
          raise(ArgumentError, "A #{source_name} is copied to in the #{modes} mode, " \
                               "supplied as `mode:`, since it holds slices of rows rather than bytes")
        end

        source = to_stream(source)
        with_lines_format(source) if mode == :line
        super(source, mode: mode, **args)
      end

      # Raises ArgumentError, rather than ignore a file name, whose streams, such as `.gz` or `.pgp`, a store of slices
      # does not apply, since it holds rows rather than bytes: set the format of the rows with #format instead, and
      # compress or encrypt the slices where they are stored. A store has no file name, so `#file_name` without an
      # argument returns nil, see `IOStreams::Stream#file_name`.
      def file_name=(_file_name)
        raise(ArgumentError, "A #{source_name} has no file name, since it holds slices of rows rather than bytes: set " \
                             "the format of the rows with #format instead, such as `format(:csv)`")
      end

      # Raises ArgumentError, since the store is only written.
      def reader(*, **)
        raise(ArgumentError, "A #{source_name} is only written: read the slices from the store itself")
      end

      # Returns [String] the class, the class of the store and the format of the rows, rather than every instance
      # variable.
      def inspect
        "#<#{self.class.name} target=#{io_stream.class.name} format=#{format.inspect}>"
      end

      protected

      # Yields the writer of the supplied mode, see #writer, with the options of the collector, see #slice_options, whose
      # slices hold whether a row whose every value is blank is a blank row, see `IOStreams::Slice#blank_rows?`.
      # Protected, so that a copy writes with the stream that has the schema of its source, see #copy_rows.
      #
      # Returns the result of the block.
      def write_slices(mode, options, blank_rows: true, &block)
        tabular = rows_tabular(blank_rows)

        Collector.write(io_stream, tabular: tabular, **options) do |collector|
          case mode
          when :line then write_lines(collector, tabular.quote_character, &block)
          when :array then block.call(IOStreams::Row::Writer.new(collector, tabular: self.tabular))
          when :hash then block.call(IOStreams::Record::Writer.new(collector, tabular: self.tabular))
          end
        end
      end

      # Returns [IOStreams::Stream] this stream, or a copy of it in the format of the lines of the supplied source of a
      # copy, when this stream has no format, see #copy_rows, so that the slices of its lines carry their format.
      # Protected, see #write_slices.
      #
      # Raises ArgumentError when this stream has a format that is not that of the source, since the lines are not
      # converted.
      def with_lines_format(source)
        lines_format = source.format
        return self if lines_format.nil? || format == lines_format

        unless format.nil?
          raise(ArgumentError, "The lines copied to a #{source_name} are in the #{lines_format.inspect} format of " \
                               "their source, not #{format.inspect}: copy rows or records in the :array or :hash " \
                               "mode to convert them")
        end

        copy        = dup
        copy.format = lines_format
        copy
      end

      private

      # Takes the lines written in the `:line` mode, see #writer, and adds the rows that they hold to the collector of the
      # slices, as a line reader would read them from the file that a line writer writes, see `IOStreams::Line::Writer`,
      # which writes a line ending after each one.
      class Lines
        # A line ending, after which the text that follows is another line, unless it is within a quoted value.
        LINE_ENDING = /[\r\n]/

        # The most bytes of text kept while a quoted value is open, as a line reader reads them, see #<<.
        MAX_PENDING_BYTES = IOStreams::Line::Reader.max_embedded_bytes

        def initialize(collector, quote_character)
          @collector       = collector
          @quote_character = quote_character
          @pending         = nil
          @quotes          = 0
          @delimiter       = nil
          @lines           = 0
        end

        # Adds the rows of the supplied line, see `IOStreams::Slice::Collector#<<`. A nil line is a blank line. A line
        # that holds a line ending, or that leaves a quoted value open, is kept until the text written holds whole rows,
        # which a line reader then splits, see #split.
        #
        # Raises `IOStreams::Errors::MalformedDataError`, with the number of the line on which the quoted value opened,
        # once the text kept while it is open exceeds the most that a line reader reads into one line, see
        # `IOStreams::Line::Reader.max_embedded_bytes`, as reading the file would, rather than keep it all in memory.
        #
        # Returns self, so that calls can be chained.
        #
        # Raises ArgumentError for a line that is not a String, such as a Hash, which the `:hash` mode writes instead.
        def <<(line)
          unless line.nil? || line.is_a?(::String)
            raise(ArgumentError, "Write each line as a String, not a #{line.class.name}, or write rows or records in " \
                                 "the :array or :hash mode")
          end

          text    = line.nil? ? "" : line
          quotes  = @quote_character ? text.count(@quote_character) : 0
          if @pending.nil? && quotes.even? && !text.match?(LINE_ENDING)
            # A line of a single row, the line ending of the file being that of the line writer.
            @delimiter ||= "\n"
            @lines      += 1
            @collector << text
          else
            (@pending ||= +"") << text << "\n"
            @quotes += quotes
            split if @quotes.even? || @pending.bytesize > MAX_PENDING_BYTES
          end
          self
        end

        alias write <<

        # Adds the rows of the text that is still kept, see #<<, once the block returns, so that a quoted value that is
        # not closed raises `IOStreams::Errors::MalformedDataError`, as reading the file would.
        def finish
          split if @pending
        end

        def inspect
          "#<#{self.class.name}>"
        end

        private

        # Adds each row of the text kept, which a line reader splits as it would read it from a file, see
        # `IOStreams::Line::Reader`, at the line ending of the file, which the first line ending written decides. The
        # reader detects it again for a file whose line ending is "\r\n", since a "\n" alone also ends a line of one.
        #
        # Raises `IOStreams::Errors::MalformedDataError` when a quoted value in the text is not closed, numbered by the
        # lines of the file, which are the lines added before the text and those of the text.
        def split
          delimiter = @delimiter unless @delimiter == "\r\n"
          io        = StringIO.new(@pending)
          reader    = IOStreams::Line::Reader.new(io, delimiter: delimiter, embedded_within: @quote_character)
          @delimiter ||= reader.delimiter
          @pending     = nil
          @quotes      = 0
          begin
            reader.each { |row| @collector << row }
          rescue IOStreams::Errors::MalformedDataError => e
            raise(e.after(@lines))
          end
          @lines += reader.line_number
        end
      end
      private_constant :Lines

      # Yields the writer of the lines in the `:line` mode to the block, see Lines, and adds the rows of the text that it
      # still keeps once the block returns, or leaves early, but not when it raises.
      def write_lines(collector, quote_character, &block)
        lines = Lines.new(collector, quote_character)
        Utils.finish_or_abort(finish: -> { lines.finish }) { block.call(lines) }
      end

      # Returns [Hash] the options of the copy, see #copy_from, those of the collector, see #slice_options.
      def copy_options(mode, args)
        slice_options(mode, args)
      end

      # Writes the rows of the source to the store in slices, see #copy_from, with the schema of the source, unless the
      # stream has its own, see `IOStreams::Stream#with_copy_schema`, and in the `:line` mode the format of its lines,
      # see #with_lines_format, whose slices hold whether the blank rows of the source are records.
      def copy_rows(source, rows, mode, options)
        target = with_copy_schema(source, mode)
        target = target.with_lines_format(source) if mode == :line
        target.write_slices(mode, options, blank_rows: source.copy_blank_rows?) { |output| rows.copy_to(output) }
      end

      def source_name
        "slice target"
      end

      # Returns [String] the modes that write rows into slices, see MODES, such as ":line, :array or :hash".
      def modes
        "#{MODES[0..-2].map(&:inspect).join(', ')} or #{MODES.last.inspect}"
      end

      # Returns [Hash] the options of the collector of the slices, see #writer: the slice size of the store, see
      # `IOStreams::Slice::Target#slice_size`, and those of the call, with their defaults.
      #
      # Raises ArgumentError for a mode other than those of MODES, or an option that the call does not take, see
      # .option_names, or a value that the collector cannot collect with, see `IOStreams::Slice::Collector.check`.
      def slice_options(mode, args)
        unless MODES.include?(mode)
          raise(ArgumentError, "A #{source_name} is written in the #{modes} mode, not " \
                               "#{mode.inspect}, since it holds slices of rows rather than bytes")
        end

        reject_unknown_options!(mode, self.class, args)
        validate = args.fetch(:validate, false)
        Collector.check_validate(validate)
        {size: slice_size, validate: validate}
      end

      # Returns [Integer] the number of rows of each slice, which the store decides, see
      # `IOStreams::Slice::Target#slice_size`.
      #
      # Raises ArgumentError when it is not a positive Integer.
      def slice_size
        size = io_stream.slice_size
        return size if size.is_a?(Integer) && size.positive?

        raise(ArgumentError, "Invalid slice_size #{size.inspect} of #{io_stream.class.name}: return the number of rows " \
                             "of each slice")
      end

      # Returns [IOStreams::Tabular] that reads the lines written into slices, see `IOStreams::Slice::Collector`, with
      # whether a row whose every value is blank is a blank row, see #write_slices.
      #
      # Raises ArgumentError for a format whose rows are not lines, such as Parquet.
      def rows_tabular(blank_rows)
        tabular = self.tabular(blank_rows: blank_rows)
        return tabular if tabular.lines?

        raise(ArgumentError, "The #{tabular.format.inspect} format has no lines, so its rows cannot be written to a " \
                             "#{source_name}")
      end
    end
  end
end
