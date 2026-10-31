# frozen_string_literal: true

module IOStreams
  module Deprecation
    # Reports a deprecation warning the first time that it applies, for an object that would otherwise report one for each
    # value that it converts, such as a field of a schema, which converts a value of each row of a file. The object holds
    # one for each of its deprecations, which is not frozen with it, so that an object that is frozen, as a field is,
    # still reports each one once.
    class Once
      # Reports the deprecation warning that the block returns, see `IOStreams::Deprecation.warn`, unless this has
      # reported it already, or deprecation warnings are off, see `IOStreams::Deprecation.on?`, when the block is not
      # called, so that a caller builds its message only when it is reported. The block returns nil when the
      # deprecation does not apply to the value at hand, which leaves it to be reported for a later one.
      #
      # Returns nil.
      def warn
        return if @reported || !Deprecation.on?

        message = yield
        return if message.nil?

        @reported = true
        Deprecation.warn(message)
      end
    end
  end
end
