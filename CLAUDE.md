# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- Tests use Minitest with the spec DSL (`describe`/`it`) inside `Minitest::Test` subclasses. Each test file does `require_relative "test_helper"` (or `"../test_helper"` under `test/paths/`).
- `test/test_helper.rb` generates PGP test keys on first run, so a working `gpg` binary is required.
- S3 and SFTP path tests skip unless env vars are set (`S3_BUCKET_NAME`; `SFTP_HOSTNAME`, `SFTP_USERNAME`, `SFTP_PASSWORD`).
- CI runs `bundle exec rake` on Ruby 3.1-3.4 and JRuby. The gem itself has zero runtime dependencies; format-specific gems (rubyzip, aws-sdk-s3, nokogiri, etc.) are dev-only and loaded lazily.

## Architecture

The public entry points are `IOStreams.path(...)` (returns a `Path` subclass based on URI scheme) and `IOStreams.stream(io)` (wraps an existing IO). Both return an `IOStreams::Stream` which is configured via chained `#stream`/`#option` calls and consumed via `#reader`, `#writer`, `#each`, `#read`, `#write`, `#copy_from`, etc.

Core pipeline (lib/io_streams/):
- `stream.rb` - `Stream` wraps an IO and delegates stream-pipeline construction to its `Builder`.
- `path.rb` - `Path < Stream`, abstract base for storage locations; concrete implementations in `paths/` (`File`, `S3`, `SFTP`, `HTTP`, plus `Matcher` for glob matching).
- `builder.rb` - `Builder` parses file-name extensions (e.g. `.csv.gz.enc`) into an ordered pipeline of reader/writer streams, merging in user-supplied `#stream`/`#option` settings. `#option` adjusts an auto-detected stream; `#stream` replaces auto-detection entirely (`:none` disables it). The two are mutually exclusive on one instance.
- `reader.rb` / `writer.rb` - base classes. Every format stream is a `Reader` (implements `#read`) or `Writer` (implements `#write`) opened via `.open`/`.stream`/`.file` class methods that yield the wrapped stream to a block. The base classes provide automatic fallback: a format that only works on files (e.g. zip, xlsx) gets the input copied to a temp file first.

Format streams live in subdirectories, each with a `Reader` and/or `Writer`: `bzip2/`, `gzip/`, `zip/`, `pgp/`, `symmetric_encryption/`, `encode/` (character encoding/cleansing), `xlsx/` (reader only), plus the structured-data layers `line/`, `row/` (arrays via `Tabular`), and `record/` (hashes via `Tabular`). `tabular.rb` handles CSV/PSV/JSON/fixed-width parsing and rendering.

Registries at the bottom of `lib/io_streams/io_streams.rb` map file extensions to reader/writer classes and URI schemes to path classes; new formats are added with `IOStreams.register_extension` / `IOStreams.register_scheme`.

Reading uses a pull model (each stream reads from the previous one on demand); writing uses a push model. See CONTRIBUTING.md for the design philosophy.

`lib/iostreams.rb` defines all autoloads; everything is lazy-loaded so optional dependencies are only required when the corresponding format is used.

`IOStreams::Pgp` shells out to the `gpg` executable rather than using a library.

## Documentation

User-facing documentation lives in the `docs/` directory as markdown files; these are what matter when reading or updating documentation. Ignore everything else in `docs/` (Jekyll config, stylesheets, etc.) from a documentation perspective.

## Conventions

- RuboCop is configured in `.rubocop.yml`: trailing-dot method chains, table-aligned hashes, max line length 128, target Ruby 2.5 syntax (`required_ruby_version >= 2.5` in the gemspec, so avoid newer syntax in lib/).
- `lib/io_streams/deprecated.rb` holds the pre-v1.6 API; it is excluded from RuboCop and not loaded into `IOStreams` by default. Avoid extending it.
