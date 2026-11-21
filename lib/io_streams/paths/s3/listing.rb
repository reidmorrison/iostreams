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
        # S3 holds `.`, `..` and `/` in a key as ordinary characters, so whoever can write an object below the prefix can
        # name a key such as `exports/../outside.csv` or `exports//etc/passwd`, whose name within the prefix leaves a
        # directory that it is joined onto, such as by `#relative_path_from` and `#join`. A key that the matcher matches
        # is only yielded when its name stays within such a directory, see `IOStreams::Utils::PathName.stays_within?`;
        # any other is skipped and logged, as is a common prefix of such a name, so that `#each_child` yields only
        # children whose names stay within the path, as on every scheme. A key that S3 folds into a common prefix, such
        # as `exports/a/../x.csv` into `exports/a/` for `*`, is not listed, so not logged.
        #
        # The prefix can be a directory within the path that is listed, from the directory of a pattern, such as `sub`
        # in `sub/**/*`, the caller's own, so `nested` says that a `/` that a name within it starts with follows another
        # name, such as in `sub//a.csv`, so that whether a key is skipped does not depend on the pattern.
        #
        # With `directories` it also yields each directory within the keys that the matcher matches, such as `a` and
        # `a/b` for the key `a/b/c.csv`, along with any empty folder created with a key ending in `/`, which is yielded
        # without the `/`.
        #
        # Only the keys directly within the prefix are listed, with the delimiter `/`, for a pattern that cannot match a
        # name below it, such as `*.csv`, and its directories are the common prefixes that S3 returns, which have empty
        # attributes, see #each_within. Otherwise every key below the prefix is listed, and its directories are found
        # from the keys, see #each_below.
        def each(prefix, matcher, directories:, nested: false, &)
          if matcher.depth&.zero?
            each_within(prefix, matcher, directories: directories, nested: nested, &)
          else
            each_below(prefix, matcher, directories: directories, nested: nested, &)
          end
        end

        # The most pages of keys that #contents lists that hold no child before it answers `:child`.
        CONTENTS_PAGES = 5

        # Returns [Symbol] what the keys below the prefix hold, see `S3#empty?`: `:child` when one of them is a key that
        # #each yields, other than the folder object of the prefix, `:none` when there are keys, but none of those, and
        # `:missing` when no key starts with the prefix. The keys that #each skips are not logged.
        #
        # Lists upto CONTENTS_PAGES pages of 1,000 keys, and answers `:child` once it has listed that many without
        # finding one, so that a prefix of many keys that #each skips takes a few requests, rather than one for each
        # page of them, though it then reads as not empty.
        def contents(prefix)
          found = :missing
          pages = 0
          each_page(prefix) do |page|
            page.contents.each do |object|
              found    = :none
              relative = object.key.delete_prefix(prefix)
              return :child if !relative.empty? && Utils::PathName.stays_within?(relative)
            end
            pages += 1
            return :child if pages >= CONTENTS_PAGES && page.next_continuation_token
          end
          found
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
        def each_within(prefix, matcher, directories:, nested:)
          each_page(prefix, delimiter: "/") do |page|
            page.contents.each do |object|
              relative = object.key.delete_prefix(prefix)
              next if object.key.end_with?("/") || !matcher.match?(relative)
              next unless within?("key", object.key, relative, prefix, nested)

              yield(object.key, object.to_h)
            end
            next unless directories

            page.common_prefixes.each do |common|
              relative  = common.prefix.delete_prefix(prefix)
              directory = relative.delete_suffix("/")
              next unless matcher.match?(directory) && within?("common prefix", common.prefix, relative, prefix, nested)

              yield("#{prefix}#{directory}", {})
            end
          end
        end

        # Yields the objects below the prefix that the matcher matches, and with `directories`, the directories within
        # their keys, see `Directories`, with empty attributes, apart from an empty folder created with a key ending in
        # `/`, which has the attributes of its object.
        def each_below(prefix, matcher, directories:, nested:)
          listed = Directories.new
          each_page(prefix) do |page|
            page.contents.each do |object|
              relative = object.key.delete_prefix(prefix)
              # The folder of the prefix itself, such as `exports/`, is neither a child nor holds a directory.
              next if relative.empty?

              # The directories of a key that is skipped are those whose names stay within the prefix, such as `a` for
              # `a/../../w.csv`, as S3 lists `a/` as a common prefix directly within the prefix.
              if directories
                listed.each_new(relative) do |directory|
                  next unless matcher.match?(directory) && stays_within?(directory, nested)

                  yield("#{prefix}#{directory}", relative == "#{directory}/" ? object.to_h : {})
                end
              end
              next if object.key.end_with?("/") || !matcher.match?(relative)
              next unless within?("key", object.key, relative, prefix, nested)

              yield(object.key, object.to_h)
            end
          end
        end

        # Returns [true|false] whether the name of a key or common prefix within the prefix stays within a directory that
        # it is joined onto, see #each, logging it when it does not.
        def within?(kind, name, relative, prefix, nested)
          return true if stays_within?(relative, nested)

          IOStreams.logger&.warn(
            "Skipping the #{kind} #{name.inspect} since its name within #{prefix.inspect} has a '.' or '..' name or a " \
            "NUL, or starts with '/', so it could name a file outside a directory that it is joined onto"
          )
          false
        end

        # Returns [true|false] whether the name within the prefix stays within a directory that it is joined onto, see
        # #each for `nested`.
        def stays_within?(relative, nested)
          Utils::PathName.stays_within?(nested ? relative.sub(%r{\A/+}, "") : relative)
        end
      end
    end
  end
end
