module IOStreams
  module Paths
    # A pattern supplied to `#each_child`, such as `"a/b/**/*.csv"`, which matches names like `Dir.glob`.
    #
    # The elements of the pattern before the first one with pattern characters are a directory, so that it is
    # listed directly rather than matched, and the rest is the pattern matched within it. Each path class lists
    # the directory within itself, and asks the matcher which names match:
    #   "a/b/c/**/*"  => directory: "a/b/c", pattern: "**/*"
    #   "a/b/c?/**/*" => directory: "a/b",   pattern: "c?/**/*"
    #   "**/*"        => directory: "",      pattern: "**/*"
    #   "a/b.csv"     => directory: "a",     pattern: "b.csv", which is #exact?
    class Matcher
      # Characters that make a pattern element match names, rather than be a name.
      PATTERN_CHARACTERS = /[*?\[{\\]/
      # A brace whose alternatives contain a directory, such as `{a,b/c}`.
      BRACE_WITH_SLASH   = /\{[^}]*\/[^}]*\}/
      # A pattern element that names a hidden file, such as `.env`.
      HIDDEN_ELEMENT     = /(?:\A|[\/{,])\./

      attr_reader :directory, :pattern, :flags

      # Parameters
      #   pattern: [String]
      #     The pattern, see `IOStreams::Paths::File#each_child`.
      #
      #   case_sensitive: [true|false]
      #     Whether the pattern is case-sensitive.
      #
      #   hidden: [true|false]
      #     Whether a wildcard matches hidden names, which start with `.`.
      def initialize(pattern, case_sensitive: false, hidden: false)
        raise(ArgumentError, "The pattern must be a String, not #{pattern.inspect}") unless pattern.is_a?(String)

        @hidden              = hidden
        @directory, @pattern = split(pattern)
        @flags               = ::File::FNM_EXTGLOB | ::File::FNM_PATHNAME
        @flags              |= ::File::FNM_CASEFOLD unless case_sensitive
        @flags              |= ::File::FNM_DOTMATCH if hidden
      end

      # Returns [true|false] whether the name, relative to the #directory, matches the pattern.
      def match?(name)
        ::File.fnmatch?(pattern, name, flags)
      end

      # Returns [true|false] whether the pattern has no pattern characters, so that it is the name of a child
      # of the #directory, which a path can look up directly rather than list.
      def exact?
        !pattern.match?(PATTERN_CHARACTERS)
      end

      # Returns [Integer] how many levels of sub-directories within the #directory the pattern can match names in,
      # or [nil] when it can match names at any level, such as with `**`.
      def depth
        return if pattern.include?("**") || pattern.match?(BRACE_WITH_SLASH)

        pattern.count("/")
      end

      # Returns [true|false] whether the pattern can match a hidden name: with `hidden: true`, or when the pattern
      # names one explicitly, such as `.env`.
      def hidden?
        @hidden || pattern.match?(HIDDEN_ELEMENT)
      end

      private

      # Returns [String, String] the directory, and the pattern within it.
      # The last element is the pattern when no element has pattern characters, so that it is matched within its
      # directory. An absolute directory without any elements is `/`.
      def split(pattern)
        elements = pattern.split("/")
        index    = elements.find_index { |element| element.match?(PATTERN_CHARACTERS) } || [elements.size - 1, 0].max
        return ["", pattern] if index.zero?

        directory = elements[0...index].join("/")
        [directory.empty? ? "/" : directory, elements[index..].join("/")]
      end
    end
  end
end
