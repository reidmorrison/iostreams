# frozen_string_literal: true

module IOStreams
  class Slice
    # The stream of a slice, see `IOStreams::Slice`, which `IOStreams.stream(slice)` returns, so that the rows of a slice
    # are read as the rows of a file are, by the settings of the stream, such as #schema:
    #
    #   IOStreams.stream(slice).schema("people.json").each(:hash) { |person| p person }
    #
    # Its rows start with the header row that the slice carries, which the tabular reads, see
    # `IOStreams::Tabular#read_header`, so that each row is read by the columns of the file that it came from, in the
    # format that the slice carries, see #format.
    #
    # A slice holds rows, already split and decoded, rather than bytes, so it raises ArgumentError for what only applies
    # to bytes: the `:stream` and `:line` modes, the streams and options of #stream and #option, an encoding, #raw, and
    # the options of lines, such as `delimiter:`. A slice is only read, so #writer, #write and #copy_from raise too.
    class Stream < IOStreams::Stream
      # Why a slice cannot be written.
      READ_ONLY = "A slice is only read: write its rows or records to a path or stream, such as with " \
                  "`copy_to(path, mode: :hash)`"
      private_constant :READ_ONLY

      # Parameters
      #   slice: [IOStreams::Slice]
      #     The rows of the slice, its header row, and the format of its rows.
      def initialize(slice)
        raise(ArgumentError, "Not a slice: #{slice.class.name}, see IOStreams.stream") unless slice.is_a?(Slice)

        super
      end

      # Yields the reader of the rows of the slice in the supplied mode, see `IOStreams::Stream#reader`: `:array`,
      # `:hash`, or `:slice`, which reads them in slices again.
      #
      # Raises ArgumentError for the `:stream` and `:line` modes, since a slice holds rows rather than bytes or lines:
      # its rows are already split, and its header row is not a line. Iterate the slice for its rows as they are.
      def reader(mode = :stream, **, &)
        if %i[stream line].include?(mode)
          raise(ArgumentError, "A slice is read in the :array, :hash or :slice mode, not #{mode.inspect}, since it holds " \
                               "rows rather than bytes or lines: iterate the slice for its rows as they are")
        end

        super
      end

      # Raises ArgumentError, since a slice is only read.
      def writer(*, **)
        raise(ArgumentError, READ_ONLY)
      end

      # Raises ArgumentError, since a slice is only read, before the source is opened.
      def copy_from(*, **)
        raise(ArgumentError, READ_ONLY)
      end

      # Returns [nil] without arguments, since no encoding is set, see `IOStreams::Stream#encoding`.
      #
      # Raises ArgumentError when an encoding, or another option of the encode stream, is supplied, since the rows of a
      # slice are text that was decoded when its file was read.
      def encoding(encoding = nil, **options)
        return super if encoding.nil? && options.empty?

        reject_bytes!("An encoding")
      end

      # Raises ArgumentError, since a slice holds rows rather than the data of a file as it is stored.
      def raw
        reject_bytes!("#raw")
      end

      # Raises ArgumentError, since a slice has no streams.
      def remove_from_pipeline(_stream_name)
        reject_bytes!("#remove_from_pipeline")
      end

      # Sets the tabular format of the rows of a slice that does not carry one, such as one turned back from a Hash
      # without a format, see `IOStreams.slice`, see `IOStreams::Stream#format=`.
      #
      # Raises ArgumentError for a format other than the one that the slice carries, since its rows are in that format.
      def format=(format)
        name = format.is_a?(::String) ? format.to_sym : format
        unless io_stream.format.nil? || name.nil? || name == io_stream.format
          raise(ArgumentError, "The rows of the slice are #{io_stream.format.inspect}, so its format cannot be " \
                               "#{format.inspect}")
        end

        super
      end

      # Returns [String] the class, the number of rows and their format, rather than every instance variable, such as
      # the rows of the slice.
      def inspect
        "#<#{self.class.name} rows=#{io_stream.size} format=#{format.inspect}>"
      end

      private

      # Returns [Symbol|nil] the format that the slice carries, which its rows are in, see
      # `IOStreams::Stream#text_format`, so that #format returns it, and reading raises for another format that is set.
      def text_format
        io_stream.format
      end

      # Raises ArgumentError for the streams and options of #stream, #option and #option_or_stream, including the
      # options of the rows of a format whose rows are not lines, such as Parquet, since the rows of a slice were read
      # when its file was read.
      def merge_options(_stream, _options)
        reject_bytes!("The streams and options of #stream and #option")
      end

      # Yields [#each] the rows of the slice, after its header row, when it carries one, which the readers of rows and
      # records read as the header row of a file, see `IOStreams::Tabular#read_header`. A header row that was already
      # parsed is read as it is, see `IOStreams::Tabular::Parser::Base`.
      #
      # Raises ArgumentError for the options of lines, `delimiter:`, `embedded_within:` and `buffer_size:`, since the
      # rows of a slice are already split.
      def open_rows_reader(_tabular, delimiter, embedded_within, buffer_size)
        options = {delimiter: delimiter, embedded_within: (embedded_within unless embedded_within == :auto),
                   buffer_size: buffer_size}
        names   = options.compact.keys
        unless names.empty?
          raise(ArgumentError, "#{names.map { |name| "#{name}:" }.join(', ')} cannot be used to read a slice, whose rows " \
                               "are already split")
        end

        slice = io_stream
        yield(Enumerator.new do |rows|
          rows << slice.header if slice.header
          slice.each { |row| rows << row }
        end)
      end

      # Raises ArgumentError for what only applies to the bytes of a file, which a slice does not have.
      def reject_bytes!(what)
        raise(ArgumentError, "#{what} cannot be used with a slice, which holds rows rather than bytes")
      end
    end
  end
end
