# frozen_string_literal: true

module IOStreams
  module Row
    # What a stream of rows, rather than of the bytes of a file, does with what only applies to bytes: the streams and
    # options of #stream and #option, an encoding, #raw, and a file name, which raise ArgumentError, naming what the
    # stream holds, see #source_name. Included by the stream of rows that were already read, see
    # `IOStreams::Row::Stream`, and the stream of a target of slices, see `IOStreams::Slice::TargetStream`.
    module WithoutBytes
      # Returns [nil] without arguments, since no encoding is set, see `IOStreams::Stream#encoding`.
      #
      # Raises ArgumentError when an encoding, or another option of the encode stream, is supplied, since the rows are
      # text that is not encoded.
      def encoding(encoding = nil, **options)
        return super if encoding.nil? && options.empty?

        reject_bytes!("An encoding")
      end

      # Raises ArgumentError, since the stream holds rows rather than the data of a file as it is stored.
      def raw
        reject_bytes!("#raw")
      end

      # Raises ArgumentError, since the stream has no streams.
      def remove_from_pipeline(_stream_name)
        reject_bytes!("#remove_from_pipeline")
      end

      # Raises ArgumentError, rather than ignore a file name, whose format and streams, such as `.json` or `.gz`, have no
      # effect on rows, saying why and what to do instead, see #file_name_reason, or FrozenError for a frozen stream. The
      # stream has no file name, so `#file_name` without an argument returns nil, see `IOStreams::Stream#file_name`.
      def file_name=(_file_name)
        raise_if_frozen!
        raise(ArgumentError, "A #{source_name} has no file name, #{file_name_reason}")
      end

      private

      # Returns [String] what the stream holds, such as "slice", which the messages of the exceptions name.
      def source_name
        raise(NotImplementedError, "#{self.class.name} must implement #source_name")
      end

      # Returns [String] why the stream has no file name, and what to do instead, which the message of #file_name= gives.
      def file_name_reason
        raise(NotImplementedError, "#{self.class.name} must implement #file_name_reason")
      end

      # Raises ArgumentError for the streams and options of #stream, #option and #option_or_stream, including the
      # options of the rows of a format whose rows are not lines, such as Parquet, since the stream has no bytes.
      def merge_options(_stream, _options)
        reject_bytes!("The streams and options of #stream and #option")
      end

      # Raises ArgumentError for what only applies to the bytes of a file, which the stream does not have.
      def reject_bytes!(what)
        raise(ArgumentError, "#{what} cannot be used with a #{source_name}, which holds rows rather than bytes")
      end
    end
  end
end
