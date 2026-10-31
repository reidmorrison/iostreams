# frozen_string_literal: true

require "fileutils"
require "open3"

# The tests of v2.2's public behavior that v3.0 keeps, so that an application that runs on v2.2 without a deprecation
# warning runs on v3.0. They live once, on the `v2` branch, in test/upgrade, since v2.2 owns that behavior, and this
# branch ignores that directory, see .gitignore.
#
# `bundle exec rake upgrade_test` runs them against this branch at the `v2` commit pinned here, so that each run is
# reproducible and a change to them reaches this branch only through a pull request that moves the pin, and
# `rake upgrade_suite_current` checks that `v2` holds that commit and has not changed them since.
module UpgradeSuite
  # The `v2` commit whose suite this branch passes. A pull request that ports a change of `v2` moves it.
  COMMIT = "437cd0a02b0126318378749b5bd739b0c667ac44"
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

  # Raises unless `v2` on origin holds COMMIT, and has not changed the suite since, naming what to do: merge the pull
  # request of `v2` that adds the suite, move COMMIT to the commit of `v2` that holds it, or port the change of `v2`,
  # listing the files that it changed. A COMMIT that `v2` does not hold, such as one of a pull request that was merged
  # as other commits, is not kept by origin for good, so it fails even when the suite is the same.
  def self.check_current
    ref = "refs/remotes/origin/#{BRANCH}"
    fetch_history("+refs/heads/#{BRANCH}:#{ref}")
    fetch(COMMIT) unless commit?(COMMIT)
    if git("ls-tree", ref, "--", DIR).empty?
      raise "#{BRANCH} has no #{DIR} yet, so it does not hold UpgradeSuite::COMMIT, #{COMMIT}: merge the pull request " \
            "of #{BRANCH} that adds the suite first."
    end
    unless ancestor?(COMMIT, ref)
      raise "#{BRANCH} does not hold UpgradeSuite::COMMIT, #{COMMIT}, such as when the pull request that it was on was " \
            "merged as other commits: move it to the commit of #{BRANCH} whose #{DIR} this branch passes, such as " \
            "#{git('rev-parse', ref).strip} when #{BRANCH} has not changed #{DIR} since."
    end
    changes = git("diff", "--name-status", COMMIT, ref, "--", DIR)
    return if changes.empty?

    raise "#{BRANCH} has changed #{DIR} since #{COMMIT}, the commit that UpgradeSuite::COMMIT pins:\n#{changes}" \
          "Port the change to this branch, then move UpgradeSuite::COMMIT to #{git('rev-parse', ref).strip}."
  end

  def self.commit?(commit)
    _output, status = Open3.capture2e("git", "-C", ROOT, "cat-file", "-e", "#{commit}^{commit}")
    status.success?
  end

  # Returns [true|false] whether the ref holds the commit, which needs the history of the ref, see .fetch_history.
  def self.ancestor?(commit, ref)
    _output, status = Open3.capture2e("git", "-C", ROOT, "merge-base", "--is-ancestor", commit, ref)
    return true if status.success?
    return false if status.exitstatus == 1

    raise "git merge-base --is-ancestor #{commit} #{ref} failed"
  end

  # Fetches from origin, keeping the shallow clone of CI shallow, without making a full clone shallow.
  def self.fetch(refspec)
    depth = shallow? ? ["--depth=1"] : []
    git("fetch", "--quiet", *depth, "origin", refspec)
  end

  # Fetches from origin with its history, which .ancestor? needs, making the shallow clone of CI a full one.
  def self.fetch_history(refspec)
    unshallow = shallow? ? ["--unshallow"] : []
    git("fetch", "--quiet", *unshallow, "origin", refspec)
  end

  def self.shallow?
    git("rev-parse", "--is-shallow-repository").strip == "true"
  end

  def self.git(*)
    run("git", "-C", ROOT, *)
  end

  def self.run(*command, stdin_data: nil)
    output, error, status = Open3.capture3(*command, stdin_data: stdin_data, binmode: true)
    raise "#{command.join(' ')} failed: #{error}" unless status.success?

    output
  end

  private_class_method :commit?, :ancestor?, :fetch, :fetch_history, :shallow?, :git, :run
end
