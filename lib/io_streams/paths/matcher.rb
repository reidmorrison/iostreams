module IOStreams
  module Paths
    # Implement fnmatch logic for any path iterator
    class Matcher
      # Characters indicating that pattern matching is required
      MATCH_START_CHARS = /[*?\[{]/.freeze

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

        @flags = ::File::FNM_EXTGLOB | ::File::FNM_PATHNAME
        @flags |= ::File::FNM_CASEFOLD unless case_sensitive
        @flags |= ::File::FNM_DOTMATCH if hidden
      end

      # Returns whether the relative `file_name` matches
      def match?(file_name)
        relative_file_name = file_name.sub(path.to_s, "").sub(%r{\A/}, "")
        ::File.fnmatch?(pattern, relative_file_name, flags)
      end

      # Whether this pattern includes a recursive match.
      # I.e. Includes `**` anywhere in the path
      def recursive?
        @recursive ||= pattern.nil? ? false : pattern.include?("**")
      end

      private

      def extract_optimized_path(path, pattern)
        elements = pattern.split("/")
        index    = elements.find_index { |e| e.match(MATCH_START_CHARS) }
        if index.nil?
          # No index means it has no pattern.
          @path    = path.nil? ? IOStreams.path(pattern) : path.join(pattern)
          @pattern = nil
        elsif index.zero?
          # Cannot optimize path since the very first entry contains a wildcard
          @path    = path || IOStreams.path
          @pattern = pattern
        else
          new_path = elements[0..index - 1].join("/")
          @path    = path.nil? ? IOStreams.path(new_path) : path.join(new_path)
          @pattern = elements[index..-1].join("/")
        end
      end
    end
  end
end
