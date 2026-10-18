# frozen_string_literal: true

module IOStreams
  class Schema
    # The schema supplied to `IOStreams::Stream#schema`: a Hash, which is checked as soon as it is supplied, or the
    # path or url of a JSON file, which is read the first time that a reader or writer needs it, so that configuring a
    # path does not read the file, nor fail when the store is not available yet, or a schema already read, see
    # `IOStreams.schema`.
    #
    # The copies of a path share its source, so that they read the file once.
    class Source
      # Parameters:
      #   source: [Hash|String|IOStreams::Stream|IOStreams::Schema]
      #     The schema, or the path or url of a JSON file that holds it.
      #
      # Raises ArgumentError when the source is none of them, or is a Hash that is not a valid schema.
      def initialize(source)
        unless source.is_a?(Hash) || source.is_a?(String) || source.is_a?(IOStreams::Stream) || source.is_a?(Schema)
          raise(ArgumentError, "A schema must be a Hash, an IOStreams::Schema, or the path or url of a JSON file: " \
                               "#{source.inspect}")
        end

        @source = source
        @schema = source.is_a?(Schema) ? source : (Schema.new(source) if source.is_a?(Hash))
      end

      # Returns [IOStreams::Schema] the schema, reading its file the first time.
      def schema
        @schema ||= Schema.read(@source)
      end
    end
  end
end
