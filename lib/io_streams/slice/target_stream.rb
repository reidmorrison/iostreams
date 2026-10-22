# frozen_string_literal: true

module IOStreams
  class Slice
    # The stream of a store of slices, see `IOStreams::Slice::Target`, which `IOStreams.stream(target)` returns, so that
    # the lines, rows or records written to it, or copied to it from a file or a query, are written to the store in
    # slices of up to `size` rows, as `IOStreams::Stream#each(:slice)` reads them from a file:
    #
    #   IOStreams.stream(store).format(:csv).schema(schema).writer(:line, size: 100) do |io|
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
    # encoding and #raw raise ArgumentError, see `IOStreams::Row::WithoutBytes`, as does a format whose rows are not
    # lines, such as Parquet. It is only written, so #reader, #each and #read raise ArgumentError too.
    class TargetStream < IOStreams::Stream
      include IOStreams::Row::WithoutBytes

      # The number of rows of each slice, unless a call supplies `size:`.
      DEFAULT_SIZE = 100

      # The modes that write rows into slices, see #writer.
      MODES = %i[line array hash].freeze

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
      #   :line   each line of a file, such as its header row followed by its rows, as `IOStreams::Stream#writer(:line)`
      #           takes them, but without a delimiter, since each one is a row.
      #   :array  each row, see `IOStreams::Row::Writer`.
      #   :hash   each record, see `IOStreams::Record::Writer`.
      #
      # Parameters
      #   size: [Integer]
      #     The number of rows of each slice, apart from the last, which holds the rows that are left.
      #     Default: 100
      #
      #   validate: [true|false]
      #     Whether to parse each row before it is added to its slice, so that a row that the format or the schema
      #     cannot read raises before the slice that holds it is written, see `IOStreams::Slice::Collector`.
      #     Default: false
      #
      # Returns the result of the block.
      #
      # Raises ArgumentError for any other mode, or option, before the block is called.
      def writer(mode = :stream, **args, &block)
        require_block!(:writer, block)
        options = slice_options(mode, args)
        tabular = rows_tabular

        Collector.write(io_stream, tabular: tabular, **options) do |collector|
          case mode
          when :line then block.call(Lines.new(collector))
          when :array then block.call(IOStreams::Row::Writer.new(collector, tabular: self.tabular))
          when :hash then block.call(IOStreams::Record::Writer.new(collector, tabular: self.tabular))
          end
        end
      end

      # Copies the lines, rows or records of the supplied source, such as a path, a stream or an Active Record query,
      # see `IOStreams::Stream#copy_from`, to the store in slices, see #writer, which takes the options of the copy, such
      # as `size:`.
      #
      # Raises ArgumentError without a `mode:`, or with `convert: false`, since the store holds slices of rows rather
      # than bytes, before the source is opened.
      def copy_from(source, convert: true, mode: nil, **args)
        unless convert && MODES.include?(mode)
          raise(ArgumentError, "A #{source_name} is copied to in the #{modes} mode, " \
                               "supplied as `mode:`, since it holds slices of rows rather than bytes")
        end

        slice_options(mode, args)
        stream = to_stream(source)
        stream.reader(mode) do |rows|
          with_copy_schema(stream, mode).writer(mode, **args) { |output| rows.copy_to(output) }
        end
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

      private

      # Takes each line written in the `:line` mode, see #writer, and adds it to the collector of the slices, as a line
      # writer of a file would write it.
      class Lines
        def initialize(collector)
          @collector = collector
        end

        # Adds the supplied line, see `IOStreams::Slice::Collector#<<`. A nil line is a blank line.
        #
        # Returns self, so that calls can be chained.
        #
        # Raises ArgumentError for a line that is not a String, such as a Hash, which the `:hash` mode writes instead.
        def <<(line)
          unless line.nil? || line.is_a?(::String)
            raise(ArgumentError, "Write each line as a String, not a #{line.class.name}, or write rows or records in " \
                                 "the :array or :hash mode")
          end

          @collector << line
          self
        end

        alias write <<

        def inspect
          "#<#{self.class.name}>"
        end
      end
      private_constant :Lines

      def source_name
        "slice target"
      end

      # Returns [String] the modes that write rows into slices, see MODES, such as ":line, :array or :hash".
      def modes
        "#{MODES[0..-2].map(&:inspect).join(', ')} or #{MODES.last.inspect}"
      end

      # Returns [Hash] the options of the collector of the slices, see #writer, with their defaults.
      #
      # Raises ArgumentError for a mode other than those of MODES, or an option that the collector does not take, or a
      # value that it cannot collect with, see `IOStreams::Slice::Collector.check`.
      def slice_options(mode, args)
        unless MODES.include?(mode)
          raise(ArgumentError, "A #{source_name} is written in the #{modes} mode, not " \
                               "#{mode.inspect}, since it holds slices of rows rather than bytes")
        end

        reject_unknown_options!(mode, Collector, args)
        options = {size: DEFAULT_SIZE, validate: false}.merge(args)
        Collector.check(**options)
        options
      end

      # Returns [IOStreams::Tabular] that reads the lines written into slices, see `IOStreams::Slice::Collector`.
      #
      # Raises ArgumentError for a format whose rows are not lines, such as Parquet.
      def rows_tabular
        tabular = self.tabular
        return tabular if tabular.lines?

        raise(ArgumentError, "The #{tabular.format.inspect} format has no lines, so its rows cannot be written to a " \
                             "#{source_name}")
      end
    end
  end
end
