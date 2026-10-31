module IOStreams
  module Xlsx
    # Stands for the writer of `.xlsx` and `.xlsm` files that IOStreams 3.0 adds, which IOStreams 2.2 does not have, see
    # `IOStreams::Xlsx::Reader.v3_writer`, and answers the options that it takes, so that one of them set with `#option`,
    # `#stream` or `#option_or_stream` is not reported as deprecated, while one that neither it nor the reader takes is,
    # since IOStreams 3.0 raises ArgumentError for it when it is set, see `IOStreams::Builder#option`. It does not write:
    # it is not registered, so writing a spreadsheet still raises ArgumentError.
    module V3Writer
      # Returns [Array<Symbol>] the options that the writer of IOStreams 3.0 takes, see
      # `IOStreams::Deprecation::OptionNames#known_option_names`.
      def self.known_option_names
        %i[sheet_name auto_format use_shared_strings]
      end
    end
  end
end
