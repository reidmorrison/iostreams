# frozen_string_literal: true

require "json"
module IOStreams
  class Tabular
    module Parser
      class Array < Base
        # Returns [:typed] each row is a Ruby object, so it holds the values themselves.
        def self.value_form
          :typed
        end

        # Returns Array
        def parse(row)
          raise(IOStreams::Errors::TypeMismatch, "Format is :array. Invalid input: #{row.class.name}") unless row.is_a?(::Array)

          row
        end

        # Returns [Array] the values of the row, in the order of its columns, as they are.
        def render(row)
          row
        end
      end
    end
  end
end
