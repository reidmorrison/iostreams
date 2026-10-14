# frozen_string_literal: true

module IOStreams
  class Tabular
    # The settings of a stream that describe its rows and records: the tabular format set with `IOStreams::Stream#format`,
    # the schema set with `IOStreams::Stream#schema`, the layout of a fixed width file set with the deprecated
    # `IOStreams::Stream#format_options`, and the options of the rows of each tabular format whose rows are not lines of
    # text, such as `option(:parquet, compression: "zstd")`, which its format reads and writes, see
    # `IOStreams::Tabular#read_rows`.
    #
    # It checks each one when it is set, decides the format of the rows, and builds the `IOStreams::Tabular` that reads
    # or writes them, see #tabular.
    #
    # A stream holds its streams and their options apart, in its builder, see `IOStreams::Builder`, since they read and
    # write its bytes, while these describe its rows, so that they are kept by `IOStreams::Stream#raw`, and need no
    # file name.
    class Settings
      def initialize
        @format         = nil
        @format_options = nil
        @schema         = nil
        @schema_source  = nil
        @row_options    = nil
      end

      # A copy has its own layout and options, so that changing them does not change the original. It shares the source
      # of the schema, which does not change, so that a schema file is read once, and the schema as it was set, which is
      # frozen.
      def initialize_copy(source)
        super
        @format_options = copy_layout(@format_options)
        @row_options    = @row_options&.transform_values(&:dup)
      end

      # Freezes these settings, holding frozen copies of their layout and options, so that neither their methods nor a
      # change to the Hashes that #format_options and #row_options return can change them, see
      # `IOStreams::Stream#freeze`. The objects that the caller supplied are not frozen.
      def freeze
        @format_options = Utils.frozen_copy(@format_options)
        @row_options    = Utils.frozen_copy(@row_options)
        super
      end

      # Returns [Symbol|nil] the format of the rows: the format that was set, see #format=, otherwise the format of the
      # text that the stream closest to the application reads and writes, when that stream decides it, which the block
      # returns, see `IOStreams::Builder#text_format`, otherwise the format detected from the file name, or nil when
      # none applies.
      def format(file_name)
        @format || yield || IOStreams::Tabular.format_from_file_name(file_name)
      end

      # Sets the tabular format, such as `:json`, or the name of one, such as "json", for a format held in configuration,
      # or nil to detect it, see #format.
      #
      # Raises ArgumentError for a format that is not registered, see `IOStreams::Tabular.registered_formats`.
      def format=(format)
        format = format.to_sym if format.is_a?(String)
        unless format.nil? || IOStreams::Tabular.registered_formats.include?(format)
          raise(ArgumentError, "Invalid format: #{format.inspect}")
        end

        @format = format
      end

      # Returns [Symbol|nil] the format that the rows, records and lines are read and written in, see #format, once the
      # format of the text of the streams is known, see `IOStreams::Builder#text_format`.
      #
      # Raises ArgumentError when the format that was set is not the format of that text, such as `:json` for a
      # spreadsheet, whose cells are read and written as CSV, rather than read or write the rows in the wrong format.
      def rows_format(file_name, text_format)
        return format(file_name) { text_format } if @format.nil? || text_format.nil? || @format == text_format

        raise(ArgumentError, "The format of the rows cannot be #{@format.inspect}, since the streams read and write them " \
                             "as #{text_format.inspect}. Set the format to #{text_format.inspect}, or to nil.")
      end

      # Returns [Hash|nil] the layout of a fixed width file that was set, see #format_options=.
      attr_reader :format_options

      # Sets the layout of a fixed width file, `layout:` and `truncate:`, which is deprecated, and replaces the schema,
      # which it is translated into, see `IOStreams::Tabular::Parser::Fixed.schema`, each time that the rows are read or
      # written, as it was used before it was deprecated, so that #schema and the file read always agree with the layout,
      # even when it is changed after it is set. Empty format options are no layout, so they keep a schema set with
      # #schema=.
      #
      # Raises `IOStreams::Errors::InvalidLayout` when the layout is not valid, and ArgumentError for an option that a
      # layout does not have, as soon as it is set, since the schema that it is translated into is checked.
      def format_options=(format_options)
        if layout?(format_options)
          IOStreams::Schema.new(IOStreams::Tabular::Parser::Fixed.schema(**format_options))
          @schema        = nil
          @schema_source = nil
        end
        @format_options = format_options
      end

      # Returns [Hash|String|IOStreams::Stream|nil] the schema as it was set, see #schema=, which is frozen, so that
      # neither the caller changing the object that it supplied, nor a change to the object that is returned, changes
      # it, or the schema of the layout of a fixed width file, see #format_options=, or nil when neither was set.
      def schema
        layout? ? IOStreams::Tabular::Parser::Fixed.schema(**@format_options) : @schema
      end

      # Sets the schema of the rows and records, see `IOStreams::Stream#schema`, which replaces a layout: a Hash, which is
      # checked now, or the path or url of a JSON file that holds one, which is read the first time that a reader or
      # writer needs it, see `IOStreams::Schema::Source`, or nil to remove it.
      #
      # A frozen copy of it is held, so that the caller changing the object that it supplied changes neither #schema nor
      # the schema that is read.
      #
      # Raises ArgumentError when the schema is not a Hash, a String or a path, or is a Hash that is not a valid schema.
      def schema=(schema)
        schema          = schema.is_a?(IOStreams::Stream) ? schema.dup.freeze : Utils.frozen_copy(schema)
        @schema_source  = schema.nil? ? nil : IOStreams::Schema::Source.new(schema)
        @schema         = schema
        @format_options = nil
      end

      # Returns [true|false] whether a format, a schema or a layout is set, which describe the rows of the file, unlike
      # the options of the rows of a tabular format, see #merge_row_options.
      def described?
        !(@format.nil? && @schema.nil? && !layout?)
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

      # Returns [IOStreams::Tabular] that reads or writes the rows in the format of the rows, see #rows_format, otherwise
      # CSV, see `IOStreams::Tabular.new`, with the schema, reading its file the first time, and the options of the rows of
      # that format, see #merge_row_options.
      #
      # The layout set with #format_options=, which is deprecated, is supplied as the layout, so that the options of each
      # call that describe its columns, such as `columns:`, still apply to it as they did before. They raise with a schema.
      #
      # Parameters:
      #   file_name: [String]
      #     The file name, from which the format is detected when no other applies.
      #
      #   text_format: [Symbol|nil]
      #     The format of the text of the stream closest to the application, see `IOStreams::Builder#text_format`.
      #
      #   The other options are those of the call that reads or writes the rows, such as `columns:`, see
      #   `IOStreams::Tabular.new`.
      def tabular(file_name:, text_format:, **)
        format = rows_format(file_name, text_format)
        row_format_options = (format && @row_options&.[](format.to_sym)) || {}
        if layout?
          IOStreams::Tabular.new(file_name: file_name, format: format, format_options: @format_options,
                                 row_format_options: row_format_options, **)
        else
          IOStreams::Tabular.new(file_name: file_name, format: format, schema: @schema_source&.schema,
                                 row_format_options: row_format_options, **)
        end
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

      private

      # Returns [true|false] whether the format options set the layout of a fixed width file: they are neither nil nor
      # empty, see #format_options=.
      def layout?(format_options = @format_options)
        !(format_options.nil? || format_options.empty?)
      end

      # Returns [Hash] a copy of the format options, whose Hashes, Arrays and Strings are copies too, so that a copy of
      # these settings that changes its layout does not change the layout of these.
      def copy_layout(value)
        case value
        when Hash then value.to_h { |key, item| [key, copy_layout(item)] }
        when Array then value.map { |item| copy_layout(item) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
