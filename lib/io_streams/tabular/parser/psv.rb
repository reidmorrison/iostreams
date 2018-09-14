module IOStreams
  class Tabular
    module Parser
      # For parsing a single line of Pipe-separated values
      class Psv < Base
        # Returns [Array<String>] the header row.
        # Returns nil if the row is blank.
        def parse_header(row)
          # return if row.blank?
          unless row.is_a?(String)
            raise(Tabular::Errors::InvalidHeader, "Format is :psv. Invalid input header: #{row.class.name}")
          end

          row.split('|')
        end

        # Returns [Array] the parsed PSV line
        def parse(row)
          # return if row.blank?
          raise(Tabular::Errors::TypeMismatch, "Format is :psv. Invalid input: #{row.class.name}") unless row.is_a?(String)

          row.split('|')
        end

        # Return the supplied array as a single line JSON string.
        def render(row, header)
          array          = header.to_array(row)
          cleansed_array = array.collect do |i|
            i.is_a?(String) ? i.tr('|', ':') : i
          end
          cleansed_array.join('|')
        end
      end
    end
  end
end
