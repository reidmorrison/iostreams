# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      # The `:none` format: rows that are held as they are, whatever they are, such as a line of text that holds a line
      # break, an Array, a number or nil, without a header row, and are never parsed. It is the format of a store of
      # slices that is not given one, see `IOStreams::Slice::TargetStream`, and of its slices, see `IOStreams::Slice`,
      # which hold and hand on their rows themselves, rather than through a tabular, so this parser only names the
      # format, and raises when a stream of a file is asked to parse or render rows in it.
      class None < Base
        # Returns [:typed] each row is a Ruby object, held as it is.
        def self.value_form
          :typed
        end

        # Raises IOStreams::Errors::TypeMismatch, since rows in the `:none` format are not parsed: they are held as they
        # are by the slices of a store of slices, see `IOStreams::Slice::TargetStream`.
        def parse(_row)
          raise(IOStreams::Errors::TypeMismatch, NOT_PARSED)
        end

        # Raises IOStreams::Errors::TypeMismatch, see #parse.
        def render(_row)
          raise(IOStreams::Errors::TypeMismatch, NOT_PARSED)
        end

        # Returns [false] the rows have no header row, unless one is written to a store of slices with them.
        def requires_header?
          false
        end

        NOT_PARSED = "The :none format holds rows as they are, without parsing them: write them to a store of slices, " \
                     "or read them from its slices, see IOStreams::Slice::TargetStream"
        private_constant :NOT_PARSED
      end
    end
  end
end
