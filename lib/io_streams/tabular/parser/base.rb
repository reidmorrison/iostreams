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

        # Returns [true|false] whether a header row is required for this format.
        def requires_header?
          true
        end
      end
    end
  end
end
