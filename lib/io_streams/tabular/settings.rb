# frozen_string_literal: true

module IOStreams
  class Tabular
    # The settings of a stream that describe its rows and records, see `IOStreams::Stream#option`: the options of the
    # rows of each tabular format whose rows are not lines of text, such as `option(:parquet, compression: "zstd")`,
    # which its format reads and writes, see `IOStreams::Tabular#read_rows`.
    #
    # A stream holds its streams and their options apart, in its builder, see `IOStreams::Builder`, since they read and
    # write its bytes, while these describe its rows, so that they are kept by `IOStreams::Stream#raw`, and need no
    # file name.
    class Settings
      def initialize
        @row_options = nil
      end

      # A copy has its own options, so that changing them does not change the original.
      def initialize_copy(source)
        super
        @row_options = @row_options&.transform_values(&:dup)
      end

      # Freezes these settings, holding frozen copies of their options, so that neither their methods nor a change to the
      # Hashes that #row_options returns can change them, see `IOStreams::Stream#freeze`. The objects that the caller
      # supplied are not frozen.
      def freeze
        @row_options = Utils.frozen_copy(@row_options)
        super
      end

      # Validates the options of the rows of the tabular format of the supplied name, such as `:parquet`, see
      # `IOStreams::Tabular.row_format`, and merges them with those already set.
      #
      # Raises ArgumentError for an option that neither the reader nor the writer of its rows accepts, as soon as it is
      # set, as for the options of a stream, see `IOStreams::StreamFormat#validate_options`.
      def merge_row_options(name, options)
        name = name.to_sym
        IOStreams::Tabular.row_format(name).validate_options(nil, options, name: name)
        @row_options ||= {}
        @row_options[name] = (@row_options[name] || {}).merge(options)
        self
      end

      # Returns [Hash|nil] the options set for the rows of the tabular format of the supplied name, see #merge_row_options,
      # or nil when none are set.
      def row_options(name)
        @row_options&.[](name.to_sym)
      end

      # Returns [Hash] the options set for the rows of the supplied tabular format, which its format reads and writes them
      # with, see `IOStreams::Tabular#read_rows`, or an empty Hash when none are set, or when the format is nil.
      def row_format_options(format)
        (format && @row_options&.[](format.to_sym)) || {}
      end

      # Returns [String] these settings for `#inspect` on a path, see `IOStreams::Path#inspect`, each one only when it is
      # set, with the value of each sensitive option replaced, as the format of the rows that they were set for decides,
      # see `IOStreams::StreamFormat#redact_options`.
      def inspect_fields
        return "" unless @row_options

        redacted = Utils.redact_streams(@row_options) { |name| IOStreams::Tabular.row_format(name) }
        " @row_options=#{redacted.inspect}"
      end

      # Does not display the values of sensitive options, see #inspect_fields.
      def inspect
        "#<#{self.class.name}#{inspect_fields}>"
      end
    end
  end
end
