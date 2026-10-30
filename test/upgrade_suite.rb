# frozen_string_literal: true

require "fileutils"
require "open3"

# The tests of v2.2's public behavior that v3.0 keeps, so that an application that runs on v2.2 without a deprecation
# warning runs on v3.0. They live once, on the `v2` branch, in test/upgrade, since v2.2 owns that behavior, and this
# branch ignores that directory, see .gitignore.
#
# `bundle exec rake upgrade_test` runs them against this branch at the `v2` commit pinned here, so that each run is
# reproducible and a change to them reaches this branch only through a pull request that moves the pin, and
# `rake upgrade_suite_current` checks whether `v2` has changed them since.
module UpgradeSuite
  # The `v2` commit whose suite this branch passes. A pull request that ports a change of `v2` moves it.
  COMMIT = "4f29e86f4fab4cecb42daadfcf7caafb55b59444"
  # The branch that owns the suite.
  BRANCH = "v2"
  # Where the suite lives on `v2`, and where it is extracted to here.
  DIR    = "test/upgrade"
  ROOT   = File.expand_path("..", __dir__)

  # Replaces test/upgrade with the suite at COMMIT, fetching the commit first when this clone does not have it, such as
  # the shallow clone of CI.
  def self.extract
    fetch(COMMIT) unless commit?(COMMIT)
    FileUtils.rm_rf(File.join(ROOT, DIR))
    run("tar", "-x", "-C", ROOT, stdin_data: git("archive", "--format=tar", COMMIT, DIR))
  end

  # Raises when `v2` on origin has changed the suite since COMMIT, listing the files that it changed.
  def self.check_current
    ref = "refs/remotes/origin/#{BRANCH}"
    fetch("+refs/heads/#{BRANCH}:#{ref}")
    fetch(COMMIT) unless commit?(COMMIT)
    changes = git("diff", "--name-status", COMMIT, ref, "--", DIR)
    return if changes.empty?

    raise "#{BRANCH} has changed #{DIR} since #{COMMIT}, the commit that UpgradeSuite::COMMIT pins:\n#{changes}" \
          "Port the change to this branch, then move UpgradeSuite::COMMIT to #{git('rev-parse', ref).strip}."
  end

  def self.commit?(commit)
    _output, status = Open3.capture2e("git", "-C", ROOT, "cat-file", "-e", "#{commit}^{commit}")
    status.success?
  end

  # Fetches from origin, keeping the shallow clone of CI shallow, without making a full clone shallow.
  def self.fetch(refspec)
    depth = git("rev-parse", "--is-shallow-repository").strip == "true" ? ["--depth=1"] : []
    git("fetch", "--quiet", *depth, "origin", refspec)
  end

  def self.git(*)
    run("git", "-C", ROOT, *)
  end

  def self.run(*command, stdin_data: nil)
    output, error, status = Open3.capture3(*command, stdin_data: stdin_data, binmode: true)
    raise "#{command.join(' ')} failed: #{error}" unless status.success?

    output
  end

  private_class_method :commit?, :fetch, :git, :run
end
