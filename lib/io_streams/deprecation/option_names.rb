# frozen_string_literal: true

module IOStreams
  module Deprecation
    # The names of the options that a reader or a writer takes in IOStreams 3.0, which `IOStreams::Reader` and
    # `IOStreams::Writer` extend, so that each of their subclasses answers them. `#option`, `#stream` and
    # `#option_or_stream` report a deprecation warning for an option that IOStreams 3.0 raises ArgumentError for when it
    # is set: one that the reader or the writer of the stream replaces, see #replaced_option_names, and one that neither
    # of them takes, see #known_option_names, such as a misspelled one, see `IOStreams::Builder#option`.
    module OptionNames
      # Returns [Array<Symbol>] the names of the options that this class takes in IOStreams 3.0 too, or [nil] when they
      # are not known, since it does not declare its options: by default those that it declares, see `.option_names`,
      # other than those that it replaces, see #replaced_option_names.
      def known_option_names
        names = option_names
        names && (names - replaced_option_names.keys)
      end

      # Returns [Hash<Symbol, Symbol>] the deprecated options that this class still takes, which IOStreams 3.0 does not,
      # with the option that replaces each, which the deprecation warning names. None by default.
      def replaced_option_names
        {}
      end
    end
  end
end
