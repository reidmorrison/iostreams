module IOStreams
  module Errors
    class Error < StandardError;
    end

    class InvalidHeader < Error;
    end

    class MissingHeader < Error;
    end

    class TypeMismatch < Error;
    end

    # When the specified delimiter is not found in the supplied stream / file
    class DelimiterNotFound < Error;
    end
  end
end
