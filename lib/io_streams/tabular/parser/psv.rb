module IOStreams
  class Tabular
    module Parser
      # For parsing a single line of Pipe-separated values
      class Psv < Base
        LINE_BREAK = /\r\n|\r|\n/
        # Returns [Array] the parsed PSV line
        def parse(row)
          return row if row.is_a?(::Array)

          raise(IOStreams::Errors::TypeMismatch, "Format is :psv. Invalid input: #{row.class.name}") unless row.is_a?(String)

          row.split("|")
        end

        # Return the supplied array as a single line PSV string.
        #
        # Since PSV has no escaping, any `|` within a value is replaced with `:`,
        # and any line break with a space, so that a value cannot add columns or records.
        def render(row, header)
          array          = header.to_array(row)
          cleansed_array = array.collect do |i|
            i.is_a?(String) ? i.tr("|", ":").gsub(LINE_BREAK, " ") : i
          end
          cleansed_array.join("|")
        end
      end
    end
  end
end
