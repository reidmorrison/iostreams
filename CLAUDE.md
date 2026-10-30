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

Core pipeline (lib/io_streams/):
- `builder.rb` - `Builder` parses file-name extensions (e.g. `.csv.gz.enc`) into an ordered pipeline of reader/writer streams, merging in user-supplied `#stream`/`#option` settings. `#option` adjusts an auto-detected stream; `#stream` replaces auto-detection entirely (`:none` disables it). The two are mutually exclusive on one instance.
- `tabular.rb` - `Tabular` reads and writes the rows and records of one file, and chooses, when it is created, how its columns map to them: `Tabular::HeaderMapping` without a schema, which holds the v2.1 behavior unchanged, including the code that the row and record readers and writers held, or `Tabular::SchemaMapping` with one (`Stream#schema`, see `schema.rb`), which follows v3's schema semantics. Tabular asks its mapping rather than branching on the schema, and the readers and writers only iterate, handing each line or value to Tabular (`#read_row`, `#render_row` and the others). Rocket Job 7.0 calls `Tabular` directly, so its v2.1 methods must keep their behavior without a schema.
- `schema.rb` - `Schema` (with `Schema::Field`, `Columns`, `Constraints`, `JsonNumber`, `Keys` and `Source`) is a Frictionless Table Schema ported from v3: it finds the field of a column and checks the columns against `fieldsMatch`; `Schema::Keys` forms the keys of the records read, as `keyType` says; `Schema::Columns` converts the rows and records of one file. A file is read as UTF-8 with a schema, unless the application chose the encoding of its text or read it with `#raw`: `Builder#utf8_text?` decides, `Line::Utf8Reader` takes the lines that a `Stream` reads as UTF-8, and `SchemaMapping` takes as UTF-8 only the binary lines that a caller of `Tabular` hands it itself (`decoded: false`), with the one rule `Utils.utf8`. Without a schema nothing of it runs.
- `reader.rb` / `writer.rb` - base classes. Every format stream is a `Reader` (implements `#read`) or `Writer` (implements `#write`) opened via `.open`/`.stream`/`.file` class methods that yield the wrapped stream to a block. The base classes provide automatic fallback: a format that only works on files (e.g. zip, xlsx) gets the input copied to a temp file first.

Registries at the bottom of `lib/io_streams/io_streams.rb` map file extensions to reader/writer classes and URI schemes to path classes; new formats are added with `IOStreams.register_extension` / `IOStreams.register_scheme`.

Reading uses a pull model (each stream reads from the previous one on demand); writing uses a push model. See CONTRIBUTING.md for the design philosophy.

`lib/iostreams.rb` defines all autoloads; everything is lazy-loaded so optional dependencies are only required when the corresponding format is used.

`IOStreams::Pgp` shells out to the `gpg` executable rather than using a library.

## Documentation

User-facing documentation is a Jekyll site under [docs/](docs/); see [docs/CLAUDE.md](docs/CLAUDE.md) for how it is built and published. **Do not add a `docs/_layouts`, `docs/stylesheets` or `docs/javascripts` directory**: the look and feel comes from the shared `rm-docs-theme`, not this repo.

## Conventions

- **API calls are strict.** An option or argument that a method does not accept must raise `ArgumentError`, never be silently ignored. Accepting and discarding options leaves callers no way to tell their setting had no effect, and some ignored options give false assurance (for example a PGP `signer:` that is dropped when reading, so no signer is verified). Declare explicit keyword arguments rather than passing `**args` or an options hash through to a dependency unchecked. Each format `Reader`/`Writer` declares `self.option_names`, and `Builder#validate_options` rejects anything else with a message that names the direction an option belongs to; keep `option_names` in sync when changing a signature (`test/stream_options_test.rb` checks it). Moving from strict to lenient is backward compatible but moving back is not, so do not relax this without an explicit, documented design, such as a separate API for reader-only and writer-only options. The one exception is BZip2, which accepted any option before v2.1: until v3.0 its `option_names` is `nil` and it logs a warning for an unknown option instead of raising. One that it takes in neither direction also reports a deprecation warning, since v3.0 raises for it, while v3.0 accepts, and ignores, an option of the other direction, which each BZip2 class answers with `known_option_names`.
- **A deprecated method or option reports a warning when it is used.** The class that owns it calls `IOStreams::Deprecation.warn` with what is deprecated and what to use instead, where the application supplies it, so that Ruby reports a deprecation warning at the line of the application, only while `Warning[:deprecated]` is on, which it is not by default. What is deprecated still works, and IOStreams never uses its own deprecated methods and options. Warn only where the public interface accepts it, such as `Stream#each`, since other gems call internal classes directly, as Rocket Job 7.0 does `IOStreams::Tabular.new` with the column options, so a warning there would name a line of that gem that its users cannot change; the public method asks the class that owns an option whether it is deprecated. `test/test_helper.rb` fails any test that causes an IOStreams deprecation warning, which it asks `IOStreams::Deprecation.warning?` to tell from the others, that it does not assert with `assert_deprecated(pattern) { ... }`.
- v2.2 is a bridge to v3.0: each deprecation names what replaces it, which v2.2 already supports, so that an application can move to it before upgrading. v2.x is maintained on the `v2` branch, and v3 on `main`. `v2` is not merged into `main`, since its code is v2.1's: a fix that applies to both branches is made on each, by its own PR, and the PR on `v2` says where the fix went on `main`, or why `main` does not need it.
- **`test/upgrade/` holds the tests of the public behavior of v2.2 that v3.0 keeps**, which `main` runs against v3.0 at a pinned commit of `v2`. They use only that API: the `IOStreams` module methods, the instance methods of the `Stream` and `Path` objects that they return, the documented error classes and `IOStreams::Row::HeaderRow`, never an internal class or a deprecated method or option, and they check the class of an error rather than a message that v3.0 words differently. A change to the public behavior of v2.2 that v3.0 keeps adds or updates a test there. A difference that v3.0 makes on purpose is a version check, `if IOStreams::VERSION.to_i >= 3`, with a comment that names the section of `docs/upgrading.md` on `main` that documents it; one that it does not document is fixed, or documented on `main`, rather than hidden behind a version check.
- The pre-v1.6 deprecated API has been removed (as of v2.0.0). Do not reintroduce it.
