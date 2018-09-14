module IOStreams
  class Tabular
    module Parser
      class Base
        # Returns [true|false] whether a header row is required for this format.
        def requires_header?
          true
        end
      end
    end
  end
end
