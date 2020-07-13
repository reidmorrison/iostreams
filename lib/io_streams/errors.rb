module IOStreams
  module Errors
    class Error < StandardError
    end

    class InvalidHeader < Error
    end

    class MissingHeader < Error
    end

    class TypeMismatch < Error
    end

    class CommunicationsFailure < Error
    end

    # When the specified delimiter is not found in the supplied stream / file
    class DelimiterNotFound < Error
    end

    # Fixed length line has the wrong length
    class InvalidLineLength < Error
    end

    class ValueTooLong < Error
    end

    class InvalidLayout < Error
    end
  end
end
