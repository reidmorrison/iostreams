# frozen_string_literal: true

require "json"
module IOStreams
  class Tabular
    module Parser
      class Hash < Base
        # Returns [:typed] each row is a Ruby object, so it holds the values themselves.
        def self.value_form
          :typed
        end

        # Returns [true] each row is a Hash, whose keys name its values.
        def self.keyed?
          true
        end

        # Returns [Hash] the record supplied, or the row supplied, an Array that is already parsed, as it is, see
        # `IOStreams::Tabular#record_parse`.
        def parse(row)
          return row if row.is_a?(::Hash) || row.is_a?(::Array)

          raise(IOStreams::Errors::TypeMismatch, "Format is :hash. Invalid input: #{row.class.name}")
        end

        # Returns [Hash] the record, by the names of its columns, as it is.
        def render(row)
          row
        end

        def requires_header?
          false
        end
      end
    end
  end
end
