# frozen_string_literal: true

module IOStreams
  class Tabular
    # The settings of a stream that describe its rows and records: the tabular format set with `IOStreams::Stream#format`,
    # the schema set with `IOStreams::Stream#schema`, the contract set with `IOStreams::Stream#as`, and the options of
    # the rows of each tabular format whose rows are not lines of text, such as `option(:parquet, compression: "zstd")`,
    # which its format reads and writes, see `IOStreams::Tabular#read_rows`.
    #
    # It checks each one when it is set, decides the format of the rows, and builds the `IOStreams::Tabular` that reads
    # or writes them, see #tabular.
    #
    # A stream holds its streams and their options apart, in its builder, see `IOStreams::Builder`, since they read and
    # write its bytes, while these describe its rows, so that they are kept by `IOStreams::Stream#raw`, and need no
    # file name.
    class Settings
      def initialize
        @format        = nil
        @schema        = nil
        @schema_source = nil
        @contract      = nil
        @row_options   = nil
      end

      # A copy has its own options, so that changing them does not change the original. It shares the source of the
      # schema, which does not change, so that a schema file is read once, and the schema as it was set, which is frozen.
      def initialize_copy(source)
        super
        @row_options = Utils.deep_copy(@row_options)
      end

      # Freezes these settings, holding a frozen copy of their options, so that neither their methods nor a change to
      # the Hashes that #row_options returns can change them, see `IOStreams::Stream#freeze`. The objects that the
      # caller supplied are not frozen.
      def freeze
        @row_options = Utils.frozen_copy(@row_options)
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
      # A format that holds the text of each row as it is, such as `:text`, also reads and writes the text of any format
      # whose rows are lines of text, such as the CSV of a spreadsheet, whose rows are split as that format splits them,
      # see `IOStreams::Tabular.verbatim_text?`, but not the values of a query, which `:array` holds.
      #
      # Raises ArgumentError when the format that was set is not the format of that text, such as `:json` for a
      # spreadsheet, whose cells are read and written as CSV, rather than read or write the rows in the wrong format.
      def rows_format(file_name, text_format)
        return format(file_name) { text_format } if @format.nil? || text_format.nil? || @format == text_format
        return @format if IOStreams::Tabular.verbatim_text?(@format, text_format)

        raise(ArgumentError, "The format of the rows cannot be #{@format.inspect}, since the streams read and write them " \
                             "as #{text_format.inspect}. Set the format to #{text_format.inspect}, or to nil.")
      end

      # Returns [IOStreams::Schema|Hash|String|IOStreams::Stream|nil] the schema as it was set, see #schema=, which is
      # frozen, so that neither the caller changing the object that it supplied, nor a change to the object that is
      # returned, changes it, or nil when none was set.
      attr_reader :schema

      # Returns [IOStreams::Schema|nil] the schema that was set, see #schema=, reading its file the first time, or nil
      # when none was set.
      def file_schema
        @schema_source&.schema
      end

      # Sets the schema of the rows and records, see `IOStreams::Stream#schema`: an `IOStreams::Schema`, a Hash, which is
      # checked now, or the path or url of a JSON file that holds one, which is read the first time that a reader or
      # writer needs it, see `IOStreams::Schema::Source`, or nil to remove it.
      #
      # A frozen copy of it is held, so that the caller changing the object that it supplied changes neither #schema nor
      # the schema that is read.
      #
      # Raises ArgumentError when the schema is not an `IOStreams::Schema`, a Hash, a String or a path, or is a Hash that
      # is not a valid schema.
      def schema=(schema)
        schema         = schema.is_a?(IOStreams::Stream) ? schema.dup.freeze : Utils.frozen_copy(schema)
        @schema_source = schema.nil? ? nil : IOStreams::Schema::Source.new(schema)
        @schema        = schema
      end

      # Returns [Class|nil] the contract that the rows and records are read and written through, see #contract=, or nil
      # when none was set.
      attr_reader :contract

      # Sets the contract that the rows and records are read and written through, see `IOStreams::Stream#as`: a contract,
      # see `IOStreams::Contract`, or a Hash or an `IOStreams::Schema` of one, which it builds, or nil to remove it.
      #
      # Raises ArgumentError for anything else, such as a record of a contract, or for a Hash or a schema that is not a
      # valid contract, such as one that lays out a file.
      def contract=(contract)
        @contract =
          case contract
          when nil then nil
          when ::Hash, IOStreams::Schema then IOStreams::Contract.new(contract)
          when Class
            unless contract < IOStreams::Contract
              raise(ArgumentError, "A contract must be a subclass of IOStreams::Contract, a Hash or an IOStreams::Schema: " \
                                   "#{contract.inspect}")
            end

            contract.schema
            contract
          else
            raise(ArgumentError, "A contract must be a subclass of IOStreams::Contract, a Hash or an IOStreams::Schema, " \
                                 "rather than #{contract.class.name}: #{contract.inspect}")
          end
      end

      # Returns [true|false] whether a format, a schema or a contract is set, which describe the rows of the file, unlike
      # the options of the rows of a tabular format, see #merge_row_options.
      def described?
        !(@format.nil? && @schema.nil? && @contract.nil?)
      end

      # Returns [true|false] whether a schema or a contract is set, which the rows are read by, rather than the schema
      # that a source of typed rows declares, see `IOStreams::Query::Stream#tabular`.
      def schema_or_contract?
        !(@schema.nil? && @contract.nil?)
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
      # Parameters:
      #   file_name: [String]
      #     The file name, from which the format is detected when no other applies.
      #
      #   text_format: [Symbol|nil]
      #     The format of the text of the stream closest to the application, see `IOStreams::Builder#text_format`.
      #
      #   default_schema: [IOStreams::Schema|nil]
      #     The schema of the rows when neither a schema nor a contract is set, which the source of the rows describes,
      #     such as that of the columns of a database query, see `IOStreams::Query::Stream`. A contract reads its typed
      #     values instead, each of which passes through when it is of the type of its field, see
      #     `IOStreams::Schema::Field#cast`.
      #
      #   The other options are those that the source of the rows supplies, see
      #   `IOStreams::Tabular::SOURCE_OPTION_NAMES`.
      def tabular(file_name:, text_format:, default_schema: nil, **)
        format = rows_format(file_name, text_format)
        row_format_options = (format && @row_options&.[](format.to_sym)) || {}
        schema = file_schema || (default_schema unless @contract)
        IOStreams::Tabular.new(file_name: file_name, format: format, schema: schema, contract: @contract&.schema,
                               row_format_options: row_format_options, text_format: text_format, **)
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
