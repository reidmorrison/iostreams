# CLAUDE.md

## Project Overview

IOStreams is a Ruby gem for streaming I/O that makes file formats, compression, encryption, and storage mechanisms (local file, S3, SFTP, HTTP) transparent to the application. Files of any size are processed one block at a time without loading them into memory.

## Commands

```bash
bundle install            # Install dependencies
bundle exec rake          # Run the full test suite (default rake task)
bundle exec ruby test/path_test.rb                 # Run a single test file
bundle exec ruby test/path_test.rb -n /partial_name/   # Run tests matching a name
bundle exec rubocop       # Lint
bundle exec rake console  # IRB with the gem loaded
```

Test notes:
- `test/test_helper.rb` generates PGP test keys on first run, so a working `gpg` binary is required.
- S3 and SFTP path tests skip unless env vars are set (`S3_BUCKET_NAME`; `SFTP_HOSTNAME`, `SFTP_USERNAME`, `SFTP_PASSWORD`).
- The gem itself has zero runtime dependencies; format-specific gems (rubyzip, aws-sdk-s3, nokogiri, etc.) are dev-only and loaded lazily.

## Architecture

The public entry points are `IOStreams.path(...)` (returns a `Path` subclass based on URI scheme) and `IOStreams.stream(io)` (wraps an existing IO). Both return an `IOStreams::Stream` which is configured via chained `#stream`/`#option` calls and consumed via `#reader`, `#writer`, `#each`, `#read`, `#write`, `#copy_from`, etc.

**Public API boundary:** The `IOStreams` module itself is the only public entry point. Everyone starts from `IOStreams.path`/`IOStreams.stream`/`IOStreams.join`, and the instance methods on the `Stream`/`Path` they return are then public. Everything else (`Path` subclasses, the `Reader`/`Writer` classes, and the format/storage submodules) is internal: nothing else should be instantiated or called directly, including method signatures like `Zip::Writer.stream`. This keeps the user-facing API tiny and lets the internals be refactored freely without breaking callers. When changing code, preserve the `IOStreams.*` module methods and the `Stream`/`Path` instance methods; treat the rest as private and changeable.

**Backward compatibility is mandatory for the public interface.** This library must never break backward compatibility in its public interface; everything else can be refactored freely as needed. The `IOStreams` module is the public interface, but whatever it returns or otherwise makes accessible is also part of that public interface. For example, `IOStreams.path` returns `Path` objects, so those are public. `Builder` is itself hidden, but its arguments and formatting options are exposed through the public API (e.g. via `#stream`/`#option` and file-name format detection), so they must remain backward compatible too. Evolve these by adding or extending new values, never by removing or changing the meaning of existing features that end users of the API may depend on.

**Paths are configuration, not code.** A path or url is meant to be externalized, for example into a centralized configuration system or an environment variable, so the exact same application code runs against local files in development and a completely different file store in staging or production. For example, while migrating production from on-prem to the cloud, the on-prem instance can use local files while the cloud instance uses S3, with only the configuration differing. Code should never need to know which file store a path refers to. So when a concept exists in one scheme, give the other schemes the equivalent form where it makes sense, even when that bends a url standard: `sftp://hostname/~/data/a.csv` is within the login directory, so `file://~/data/a.csv` is within the home directory, letting one setting switch between the two. Likewise, keep path operations behaving the same across schemes.

Core pipeline (lib/io_streams/):
- `builder.rb` - `Builder` parses file-name extensions (e.g. `.csv.gz.enc`) into an ordered pipeline of reader/writer streams, merging in user-supplied `#stream`/`#option` settings, and asks each stream's format to open it. `#option` adjusts an auto-detected stream; `#stream` replaces auto-detection entirely (`:none` disables it). The two are mutually exclusive on one instance.
- `reader.rb` / `writer.rb` - base classes. Every format stream is a `Reader` (implements `#read`) or `Writer` (implements `#write`) opened via `.open`/`.stream`/`.file` class methods that yield the wrapped stream to a block. The base classes provide automatic fallback: a format that only works on files (e.g. zip, xlsx) gets the input copied to a temp file first.

Registries at the bottom of `lib/io_streams/io_streams.rb` map file extensions to formats and URI schemes to path classes; new formats are added with `IOStreams.register_extension` / `IOStreams.register_scheme`. A format is a module, such as `IOStreams::Gzip` in `lib/io_streams/gzip.rb`, that answers `reader_class`, `writer_class`, `compressed?` and `encrypted?`, and extends `IOStreams::StreamFormat`, which combines the options of its reader and writer, checks them, and opens the reader or writer with the options it uses. A format that file names do not name, such as `:encode`, answers `file_name_extension?` with false, so that it applies whenever its options are set. Facts about a format's data, and anything that combines both directions, belong on its module; its `Reader` and `Writer` hold what applies to one direction, such as `option_names`. A format registered with just its reader and writer classes is wrapped in a frozen `IOStreams::Extension`, which is neither compressed nor encrypted.

Reading uses a pull model (each stream reads from the previous one on demand); writing uses a push model. See CONTRIBUTING.md for the design philosophy.

`lib/iostreams.rb` defines the top-level autoloads, and each format module autoloads its own reader and writer; everything is lazy-loaded so optional dependencies are only required when the corresponding format is used.

`IOStreams::Pgp` shells out to the `gpg` executable rather than using a library.

## Documentation

User-facing documentation is a Jekyll site under [docs/](docs/); see [docs/CLAUDE.md](docs/CLAUDE.md) for how it is built and published. **Do not add a `docs/_layouts`, `docs/stylesheets` or `docs/javascripts` directory**: the look and feel comes from the shared `rm-docs-theme`, not this repo.

## Conventions

- **API calls are strict.** An option or argument that a method does not accept must raise `ArgumentError`, never be silently ignored. Accepting and discarding options leaves callers no way to tell their setting had no effect, and some ignored options give false assurance (for example a PGP `signer:` that, if dropped when reading, would check no signer). Declare explicit keyword arguments rather than passing `**args` or an options hash through to a dependency unchecked. Each format `Reader`/`Writer` declares `self.option_names`, the keywords it takes, and only those are passed to it; keep it in sync when changing a signature (`test/stream_options_test.rb` checks it). A `Reader`/`Writer` also declares `self.sensitive_option_names`, those of its options that hold a secret, such as a PGP `passphrase`, so that `#inspect` does not display them. One option hash is shared by a stream's reader and writer, so that a path can be written and then read, so by default each direction also accepts the other direction's `option_names` and ignores them, such as `compress` when reading `.enc`, whose header records it; `IOStreams::StreamFormat#valid_option_names` computes this from the format's reader and writer. `Builder#option`/`#stream` reject a name that neither direction accepts as soon as it is set, even for a stream the file name does not include. When adding an option, check whether a caller could expect it to have an effect in the other direction, such as the PGP `signer` before the reader checked it; if so, override `self.valid_option_names` in that direction's class to exclude it, so that `IOStreams::StreamFormat#validate_options` raises with a message that names the direction it belongs to, until that direction supports it. Moving from strict to lenient is backward compatible but moving back is not, so once released, an option that the other direction ignores can never raise there again.
- **A stream never closes the IO supplied to it.** Whoever opens an IO closes it: a format `Reader`/`Writer` closes only what it opened itself, such as its own wrapper object or a file it opened by name in `.file`, and leaves the IO passed to `.stream` open for the caller. Many wrappers close the IO underneath them, for example `Zlib::GzipWriter#close` and `SymmetricEncryption::Writer.open`, so end them without closing it: `#finish` for Zlib, `close(false)` for SymmetricEncryption, `autoclose: false` for bzip2-ffi. `test/stream_close_test.rb` checks every registered stream that has both a reader and a writer.
- The pre-v1.6 deprecated API has been removed (as of v2.0.0). Do not reintroduce it.
