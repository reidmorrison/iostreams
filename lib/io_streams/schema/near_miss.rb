# frozen_string_literal: true

module IOStreams
  class Schema
    # The property that the name of a property of a schema or a field that IOStreams does not know is close to, such as
    # `trueValues` for `trueValue`, so that a mistyped property raises, rather than be kept as a property of another
    # tool, which Frictionless accepts, and have no effect, see `IOStreams::Schema` and `IOStreams::Schema::Field`.
    module NearMiss
      # Returns [String|nil] the first of the known names that the name is close to, or nil when it is close to none, or
      # holds a `:`, as the properties of other tools do, such as `mytool:owner`. A name is close to a known name that it
      # is once both are lowercase, such as `groupchar` for `groupChar`, or that it is one edit from, a character added,
      # left out or replaced, or two characters next to each other swapped, such as `contraints` for `constraints`, or
      # `trueValue` for `trueValues`.
      def self.find(name, known_names)
        return if name.include?(":")

        lower = name.downcase
        known_names.find { |known| close?(lower, known.downcase) }
      end

      # Returns [true|false] whether the lowercase names are the same, or one edit apart.
      def self.close?(name, known)
        return true if name == known
        return false if (name.length - known.length).abs > 1

        name.length == known.length ? replaced_or_swapped?(name, known) : added_or_left_out?(name, known)
      end

      # Returns [true|false] whether names of the same length differ by one character, or by two characters next to each
      # other that are swapped.
      def self.replaced_or_swapped?(name, known)
        differ = (0...name.length).reject { |index| name[index] == known[index] }
        return true if differ.size == 1
        return false unless differ.size == 2 && differ.last == differ.first + 1

        name[differ.first] == known[differ.last] && name[differ.last] == known[differ.first]
      end

      # Returns [true|false] whether names whose lengths differ by one are the same once a character is added to the
      # shorter one.
      def self.added_or_left_out?(name, known)
        short, long = name.length < known.length ? [name, known] : [known, name]
        index = 0
        index += 1 while index < short.length && short[index] == long[index]
        short[index..] == long[(index + 1)..]
      end

      private_class_method :close?, :replaced_or_swapped?, :added_or_left_out?
    end
  end
end
