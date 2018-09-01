module IOStreams
  module Tabular
    module Errors
      class Error < StandardError;
      end

      class InvalidHeader < Error;
      end

      class TypeMismatch < Error;
      end
    end
  end
end
