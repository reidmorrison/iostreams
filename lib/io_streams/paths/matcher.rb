module IOStreams
  module Paths
    # Implement fnmatch logic for any path iterator
    class Matcher
      # Characters indicating that pattern matching is required
      MATCH_START_CHARS = /[*?\[{]/

      attr_reader :path, :pattern, :flags

      # If the supplied pattern contains sub-directories without wildcards, navigate down to that directory
      # first before applying wildcard lookups from that point on.
      #
      # Examples: If the current path is "/path/work"
      #   "a/b/c/**/*"  => "/path/work/a/b/c"
      #   "a/b/c?/**/*" => "/path/work/a/b"
      #   "**/*"        => "/path/work"
      #
      # Note: Absolute paths in the pattern are not supported.
      def initialize(path, pattern, case_sensitive: false, hidden: false)
        extract_optimized_path(path, pattern)

        @flags = ::File::FNM_EXTGLOB
        @flags |= ::File::FNM_CASEFOLD unless case_sensitive
        @flags |= ::File::FNM_DOTMATCH if hidden
      end

      # Returns whether the relative `file_name` matches
      def relative_match?(relative_file_name)
        ::File.fnmatch?(pattern, relative_file_name, flags)
      end

      def absolute_match?(_absolute_file_name)
        raise NotImplementedError
        # ::File.fnmatch?(pattern, absolute_file_name, flags)
      end

      def recursive?
        @recursive
      end

      # # Returns whether the pattern is actually a pattern or just a file exists check.
      # def pattern?
      #
      # end

      private

      def extract_optimized_path(path, pattern)
        elements = pattern.split('/')
        index    = elements.find_index { |e| e.match(MATCH_START_CHARS) }
        if index == 0
          # Cannot optimize path since the very first entry contains a wildcard
          @path    = path
          @pattern = pattern
        elsif index.nil?
          # No index means it has no pattern.
          # TODO: Could be optimized into an existence check instead of iterating over every element.
          @path    = elements.size > 1 ? path.join(*elements[0..-2]) : path
          @pattern = elements[-1]
        else
          @path    = path.join(*elements[0..index - 1])
          @pattern = elements[index..-1]
        end
      end

    end
  end
end
