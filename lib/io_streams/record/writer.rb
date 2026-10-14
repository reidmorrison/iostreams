# frozen_string_literal: true

module IOStreams
  module Record
    # Example, implied header from first record:
    #   IOStreams.path('file.csv').writer(:hash) do |stream|
    #     stream << {name: 'Jack', address: 'Somewhere', zipcode: 12345}
    #     stream << {name: 'Joe', address: 'Lost', zipcode: 32443, age: 23}
    #   end
    #
    # `IOStreams::Stream#writer(:hash)` creates it with the tabular of the stream, whose options are documented with
    # `IOStreams::Tabular.new`. The options that restrict the columns read, `allowed_columns`, `required_columns` and
    # `skip_unknown`, only apply when reading, so `IOStreams::Stream#writer` raises ArgumentError for them.
    class Writer
      # Returns [Array<Symbol>] the options of each call that writes records, see `IOStreams::Stream#writer`, which raises
      # for any other: those of the lines that it writes, see `IOStreams::Line::Writer.option_names`, and those of the
      # `IOStreams::Tabular` that renders them, see `IOStreams::Tabular.write_option_names`.
      def self.option_names
        [*IOStreams::Line::Writer.option_names, *IOStreams::Tabular.write_option_names]
      end

      # Returns [Array<Symbol>] the options of .option_names that are deprecated, which a call still accepts: those of the
      # lines that it writes, see `IOStreams::Line::Writer.deprecated_option_names`, and of the tabular that renders them,
      # see `IOStreams::Tabular.deprecated_option_names`.
      def self.deprecated_option_names
        [*IOStreams::Line::Writer.deprecated_option_names, *IOStreams::Tabular.deprecated_option_names] & option_names
      end

      # Create a writer that takes individual records as hashes.
      #
      # Parameters
      #   line_writer: [#<<]
      #     Anything that accepts a line / record at a time when #<< is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Renders each record in its format, and holds the header.
      def initialize(line_writer, tabular:)
        raise(ArgumentError, "Stream must be a IOStreams::Line::Writer or implement #<<") unless line_writer.respond_to?(:<<)

        @tabular     = tabular
        @line_writer = line_writer

        # The header line of the columns supplied, or of the fields of a schema, see `IOStreams::Tabular#start_records`.
        @tabular.start_records { |line| @line_writer << line }
      end

      # Writes the record, after the header line that the keys of the first record give, when neither the columns
      # supplied nor a schema give it, see `IOStreams::Tabular#render_record`.
      #
      # Returns self, so that calls can be chained.
      def <<(hash)
        raise(ArgumentError, "#<< only accepts a Hash argument") unless hash.is_a?(Hash)

        @tabular.render_record(hash) { |line| @line_writer << line }
        self
      end

      # Returns [String] the class and the format of the records, see `IOStreams::Tabular#format`, rather than every
      # instance variable, such as the tabular and the lines that it writes, so that irb, which displays what a writer
      # block returns, such as the writer that `io << record` returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end
    end
  end
end
