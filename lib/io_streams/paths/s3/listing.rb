# frozen_string_literal: true

module IOStreams
  module Paths
    class S3 < IOStreams::Path
      # Lists the objects whose keys start with a prefix, one page of upto 1,000 objects at a time, for `S3#each_child`
      # and `S3#delete_all`.
      #
      # S3 has no directories, only keys that contain `/`, so the directories within the keys are found from the keys
      # within them, see `Directories`.
      #
      # Used internally by the S3 path, which makes each `list_objects_v2` request, so that it supplies its bucket and
      # options, and tags each failure.
      class Listing
        # Parameters:
        #   request: [Proc]
        #     Makes a `list_objects_v2` request with the supplied parameters, and returns its response.
        def initialize(request)
          @request = request
        end

        # Yields [String, Hash] the key and the attributes, the hash of the object listed by S3, of each object whose
        # key, relative to the prefix, the matcher matches.
        #
        # With `directories` it also yields each directory within the keys that the matcher matches, such as `a` and
        # `a/b` for the key `a/b/c.csv`, along with any empty folder created with a key ending in `/`, which is yielded
        # without the `/`. The attributes of a directory are empty, unless it is such a folder.
        def each(prefix, matcher, directories:)
          listed = Directories.new
          each_page(prefix) do |page|
            page.contents.each do |object|
              relative = object.key.delete_prefix(prefix)
              if directories
                listed.each_new(relative) do |directory|
                  yield("#{prefix}#{directory}", relative == "#{directory}/" ? object.to_h : {}) if matcher.match?(directory)
                end
              end
              next if object.key.end_with?("/") || !matcher.match?(relative)

              yield(object.key, object.to_h)
            end
          end
        end

        # Yields each page of upto 1,000 objects whose keys start with the prefix.
        def each_page(prefix)
          token = nil
          loop do
            page = @request.call(prefix: prefix, continuation_token: token)
            yield(page)
            break unless (token = page.next_continuation_token)
          end
        end
      end
    end
  end
end
