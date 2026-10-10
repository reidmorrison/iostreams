module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # The directories within the keys of one listing. S3 has no directories, only keys that contain `/`, so each
      # directory is found from the keys within it, and is yielded once however many keys it holds.
      class Directories
        def initialize
          @listed = {}
        end

        # Yields the name of each directory within the relative key that has not already been yielded,
        # such as `a` and `a/b` for `a/b/c.csv`, or for the empty folder `a/b/`.
        def each_new(relative)
          elements = relative.split("/")
          elements.pop unless relative.end_with?("/")
          elements.each_index do |index|
            break if elements[index].empty?

            directory = elements[0..index].join("/")
            next if @listed.key?(directory)

            @listed[directory] = true
            yield(directory)
          end
        end
      end
    end
  end
end
