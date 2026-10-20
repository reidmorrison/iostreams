module IOStreams
  class Tabular
    module Parser
      class Base
        # Returns [String] the quote character within which field delimiters and embedded
        # newlines may appear for this format, or [nil] when the format has no such quoting.
        #
        # Used by the line reader to avoid treating a newline as a line ending when it is
        # embedded within a quoted field (e.g. CSV). Defined at the class level since it is a
        # static property of the format, independent of any per-instance format options.
        def self.quote_character
          nil
        end

        # Returns [true|false] whether each row of this format is a record, a Hash whose keys name its values, such as a
        # line of JSON, rather than its values in the order of its columns, an Array, such as a line of CSV, so that a
        # schema arranges the values of each row that is written in the form that the parser renders, see
        # `IOStreams::Tabular::SchemaMapping`.
        #
        # Defined at the class level since it is a static property of the format, see `.quote_character`.
        def self.keyed?
          false
        end

        # Returns [:text|:json|:typed] the form in which this format writes the values of a schema, see
        # `IOStreams::Schema::Field#render`: as text, the default.
        def self.value_form
          :text
        end

        # Returns [IOStreams::Tabular::Parser::Base] the parser of the lines of this format for the supplied schema, see
        # `IOStreams::Tabular.new`: a parser of this format, whose lines are the same with a schema, which arranges the
        # values of each row itself, see `IOStreams::Tabular::SchemaMapping`. A format whose lines depend on the schema,
        # such as fixed width, whose fields give the positions in the line, returns a parser of its own.
        def self.schema_parser(_schema)
          new
        end

        # Returns [true|false] whether a header row is required for this format.
        def requires_header?
          true
        end
      end
    end
  end
end
