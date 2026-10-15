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
        # without the `/`.
        #
        # Only the keys directly within the prefix are listed, with the delimiter `/`, for a pattern that cannot match a
        # name below it, such as `*.csv`, and its directories are the common prefixes that S3 returns, which have empty
        # attributes, see #each_within. Otherwise every key below the prefix is listed, and its directories are found
        # from the keys, see #each_below.
        def each(prefix, matcher, directories:, &)
          if matcher.depth&.zero?
            each_within(prefix, matcher, directories: directories, &)
          else
            each_below(prefix, matcher, directories: directories, &)
          end
        end

        # Yields each page of upto 1,000 objects whose keys start with the prefix, with the supplied parameters of the
        # request, such as a delimiter.
        def each_page(prefix, **params)
          token = nil
          loop do
            page = @request.call(prefix: prefix, continuation_token: token, **params)
            yield(page)
            break unless (token = page.next_continuation_token)
          end
        end

        private

        # Yields the objects directly within the prefix that the matcher matches, and with `directories`, the
        # directories directly within it, from the common prefixes of a listing with the delimiter `/`, with empty
        # attributes, since S3 lists them by name only, including an empty folder created with a key ending in `/`.
        def each_within(prefix, matcher, directories:)
          each_page(prefix, delimiter: "/") do |page|
            page.contents.each do |object|
              relative = object.key.delete_prefix(prefix)
              yield(object.key, object.to_h) if !object.key.end_with?("/") && matcher.match?(relative)
            end
            next unless directories

            page.common_prefixes.each do |common|
              directory = common.prefix.delete_prefix(prefix).delete_suffix("/")
              yield("#{prefix}#{directory}", {}) if matcher.match?(directory)
            end
          end
        end

        # Yields the objects below the prefix that the matcher matches, and with `directories`, the directories within
        # their keys, see `Directories`, with empty attributes, apart from an empty folder created with a key ending in
        # `/`, which has the attributes of its object.
        def each_below(prefix, matcher, directories:)
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
      end
    end
  end
end
