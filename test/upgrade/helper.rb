# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The helpers that the tests of test/upgrade share, which a describe block includes: the files of a temporary
# directory, which is made only for a test that uses it, and the lines, rows or records that a stream yields. The name
# of this file does not end in _test.rb, since both branches run each file of test/upgrade that does as a test, see
# `test/upgrade/` in CLAUDE.md.
module UpgradeHelper
  # Returns [String] the temporary directory of the test, which is made the first time that the test asks for it.
  def dir
    @dir ||= Dir.mktmpdir("iostreams")
  end

  # Removes the temporary directory of the test, when it made one.
  def teardown
    FileUtils.rm_rf(@dir) if @dir
    super
  end

  # Returns [IOStreams::Path] the path of the file within the temporary directory.
  def path(name)
    IOStreams.path(dir, name)
  end

  # Writes the bytes to the file within the temporary directory, as they are.
  def store(name, data)
    ::File.binwrite(::File.join(dir, name), data)
  end

  # Returns [String] the bytes of the file within the temporary directory, as they are stored.
  def stored(name)
    ::File.binread(::File.join(dir, name))
  end

  # Returns [Array] the lines, rows or records that the stream yields, with the mode and options of #each, whose
  # default mode it shares.
  def read(stream, mode = :line, **)
    rows = []
    stream.each(mode, **) { |row| rows << row }
    rows
  end
end
