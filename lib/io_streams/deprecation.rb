module IOStreams
  # Reports the use of a deprecated method or option as a Ruby deprecation warning, see `Kernel#warn`, so that Ruby
  # decides whether and where it is reported, as it does for its own deprecations, rather than a setting of IOStreams:
  # - Only while deprecation warnings are on, see `Warning[:deprecated]`. They are off by default, so production stays
  #   quiet, and on in tests run by Minitest or test-unit, or with `ruby -W:deprecated` or `RUBYOPT=-W:deprecated`.
  # - Written to `$stderr`, unless the application routes them elsewhere, such as to its log, or raises them in its
  #   tests, by overriding `Warning.warn`.
  #
  # Each warning names the line of the application that used what is deprecated, rather than a line of IOStreams.
  module Deprecation
    # The directory of the files of this library, whose lines are skipped when finding the line that used it.
    LIB_DIR = "#{File.expand_path('..', __dir__)}/".freeze

    # Reports that the application used something deprecated, unless deprecation warnings are off, with the message,
    # which says what is deprecated and what to use instead, after "IOStreams: ", at the first line of the call stack
    # outside this library.
    #
    # Returns nil.
    def self.warn(message)
      return unless Warning[:deprecated]

      uplevel = caller_locations(1).index { |location| !library?(location) }
      # Kernel#warn counts its own caller, this method, as level 0.
      Kernel.warn("IOStreams: #{message}", uplevel: uplevel && (uplevel + 1), category: :deprecated)
      nil
    end

    # Returns [true|false] whether the line of the call stack is in a file of this library. Code run with `eval` has
    # only the file name that it was given.
    def self.library?(location)
      (location.absolute_path || location.path).start_with?(LIB_DIR)
    end
    private_class_method :library?
  end
end
