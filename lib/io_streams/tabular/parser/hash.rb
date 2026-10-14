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

        def parse(row)
          raise(IOStreams::Errors::TypeMismatch, "Format is :hash. Invalid input: #{row.class.name}") unless row.is_a?(::Hash)

          row
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
