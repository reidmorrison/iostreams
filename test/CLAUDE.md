# test

Conventions for writing tests. How to run them, and the gotchas of running them in a worktree or on JRuby, are in the [root CLAUDE.md](../CLAUDE.md); the query tests are in [lib/io_streams/query/CLAUDE.md](../lib/io_streams/query/CLAUDE.md).

- **Assert the exact class.** Prefer `assert_kind_of SomeStream, io` (or `assert_instance_of`) over duck-type checks such as `io.respond_to?(:write)`: an exact class proves the pipeline returned the right object, while a duck-type check passes for any wrong object that shares the interface. Do not loosen an existing class assertion as a cleanup, even when it names a gem's class.
- **Assert values, not just that nothing raised.** A test of encoding, casting or PGP checks the bytes, values or trust that result, so that a bug that changes them fails the test.
- **CI also runs Ruby 3.3**, whose `Hash#inspect` gives `{:a=>1}` rather than 3.4's `{a: 1}`: build an expected message that holds a Hash with `hash.inspect`, never as a literal.
- **A failure before the target opens** is tested with a copy or write to an existing file, whose contents must survive. A read that a regression could repeat without end, such as a block that updates the rows that it reads, breaks after a number of rows, so the test fails rather than hangs.
- **PGP tests supply the right passphrase.** `test_helper.rb` sets `default-cache-ttl 0` for the test keyring's gpg-agent, so a passphrase is never served from the cache, and `auto-key-locate local`, so a missing recipient is never looked up over the network. Running PGP tests concurrently in one checkout corrupts results, since they share the keyring and its lock files. Never point a mutation of a destructive key guard, such as that of `Pgp.delete_public_or_private_keys`, at the test keyring: it deletes every secret key in `tmp/gnupg`.
- **Deprecations:** `test_helper.rb` fails any test that causes an IOStreams deprecation warning it does not assert with `assert_deprecated(pattern) { ... }`.
