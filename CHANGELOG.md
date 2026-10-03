# Changelog

All notable changes to this project are documented here.

This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Breaking

- **Stream options are now strict.** An option supplied via `#option` or `#stream` that the stream does not accept now raises `ArgumentError` instead of being silently ignored. This only affects code that was passing invalid options:
  - The BZip2 reader and writer previously accepted any option and ignored the ones `bzip2-ffi` does not use. They now accept only `autoclose`, `first_only` and `small` when reading, and `autoclose`, `block_size` and `work_factor` when writing.
  - Every other stream already raised `ArgumentError` for an option it does not accept, so the only change there is a clearer error message.
- **`allowed_columns`, `required_columns` and `skip_unknown` now apply to every input when reading records.** Previously they were only applied to a header row read from the file, and only when `cleanse_header` was true, so they were silently ignored for JSON and `:hash` input, when `columns:` was supplied, and with `cleanse_header: false`. Since the format is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypassed the allow list. When either `allowed_columns` or `required_columns` is set, JSON keys are now cleansed like a header row (for example `"Name"` becomes `"name"`), unknown keys are skipped or raise `IOStreams::Errors::InvalidHeader`, and a record missing a required column raises `IOStreams::Errors::InvalidHeader`. Reading without these options, and writing, are unchanged.
- **`IOStreams::Pgp.delete_keys` requires an `email:` or `key_id:`.** Calling it with neither now raises `ArgumentError`. Previously, on GnuPG 2.1 and later, it deleted every key in the keyring (and with `private: true`, every secret key). To delete several keys, call it once per email or key id, for example for each key returned by `IOStreams::Pgp.list_keys`.
- **`IOStreams::Pgp.export` raises `ArgumentError` when neither `email:` nor `key_id:` is supplied**, instead of `Pgp::Failure` for `email: nil`. It also accepts `key_id:` as an alternative to `email:`.

### Changed

- The `ArgumentError` for an option supplied to a stream now says what is wrong. When the option only applies in the other direction, for example `option(:enc, compress: false)` when reading, the message names the direction it belongs to and suggests configuring a separate path for reading. Otherwise it lists the valid options. Previously the error was Ruby's `unknown keyword`, raised from inside the gem that implements the stream. See [#38](https://github.com/reidmorrison/iostreams/issues/38).

### Security

- SFTP: a `username:` starting with `-` could be read by the `sftp` executable as an option, for example `-D` to run a local command. The destination is now preceded by `--`, and usernames that start with `-` or contain control characters raise `ArgumentError`.
- PGP: email addresses and key ids are now preceded by `--` when passed to `gpg`, so a value such as `--comment=x@example.com` can no longer be read as an option (which matched every key in the keyring).
- PGP: the signer passphrase and the `export(passphrase:)` passphrase are now supplied to `gpg` on a file descriptor instead of the command line, so they are no longer visible in the process list.
- Internal temp files, which can hold decrypted data such as the plaintext of a `.zip.pgp` file, are now created with mode `0600` and fail rather than reuse an existing file or link.
- S3 and SFTP `#each_child` no longer reparse remote file names as URLs, so a name containing `?`, `+` or `%` can no longer change the child path or add S3 request parameters.
- SFTP `#each_child` now requires a known host key, matching the `sftp` executable's `StrictHostKeyChecking=yes`, instead of trusting a host key the first time it is seen.
- Credentials are no longer included in HTTP error messages, in the `sftp` output included in SFTP errors, or in the passphrase options displayed by `Path#inspect`.
- Removed an unused line that merged the SFTP URL query string into the ssh options. It currently had no effect, but would have allowed options such as `?ProxyCommand=...` to run commands if it were ever fixed.
- Reading a CSV file with an unbalanced quote no longer takes quadratic time.
- Documented that an S3 URL query string is added to the S3 request parameters, and that untrusted file names should be added with `#join` rather than interpolated into the URL.

### Fixed

- `Path#join` and `IOStreams.join` only return an element unchanged when it is the path itself or is inside it. Previously any element that merely started with the same characters was returned as-is, so `IOStreams.path("s3://bucket/reports").join("reports_2024.csv")` gave `s3://bucket/reports_2024.csv` instead of `s3://bucket/reports/reports_2024.csv`, and with a root of `/data/uploads`, `join("/data/uploads_other/secret.csv")` escaped the root. Elements containing `..` are still joined as supplied.

- When writing PSV or fixed width files, line breaks within a value are now replaced with a space. Previously a value such as `"Jack\nFORGED"` wrote a separate record. PSV already replaced `|` with `:` for the same reason.

### Added

- The GZip writer accepts a `level` option to set the compression level, for example `option(:gz, level: 9)`. Previously any option raised `ArgumentError`.

## [2.0.0] - 2026-06-19

### Breaking

- Ruby 3.2 is now the minimum supported version. Older Rubies are no longer tested or supported.
- Removed the deprecated pre-v1.6 API mix-in (`lib/io_streams/deprecated.rb` is no longer loaded). Code still relying on the deprecated methods must migrate to the current `IOStreams.path` / `IOStreams.stream` API.
- **Zip writing now uses the `zip_kit` gem instead of the retired `zip_tricks`.** `zip_tricks` has been retired by its author in favor of `zip_kit`. Applications that **write** Zip files must replace `gem "zip_tricks"` with `gem "zip_kit"` in their Gemfile (the zip writer is an optional soft dependency that you declare yourself). The IOStreams API and streaming behavior are unchanged. Reading Zip files is unaffected (still `rubyzip`, or the built-in Java support on JRuby).
- Removed the deprecated `compression:` option from the PGP writer. Use `compress:` instead (available since v1.11.0).
- `IOStreams::Pgp.fingerprint` is now a private method. Identify keys by `key_id` via the public `IOStreams::Pgp.list_keys` / `IOStreams::Pgp.key_info` instead.
- Removed `IOStreams::Pgp.logger` and `IOStreams::Pgp.logger=`. Logging is now configured centrally via `IOStreams.logger` / `IOStreams.logger=`, which the entire library (including PGP and SFTP) uses. Replace `IOStreams::Pgp.logger = my_logger` with `IOStreams.logger = my_logger`.

### Added

- `IOStreams.logger` / `IOStreams.logger=` provide a single logging configuration point for the entire library. [Semantic Logger](https://logger.reidmorrison.com) is detected automatically when loaded; otherwise assign any standard logger, or set it to `nil` to disable logging.
- Gem metadata links (bug tracker, changelog, documentation, source code) added to the gemspec.
- `csv` is now declared as a runtime dependency. It was a Ruby default gem through 3.3 but became a bundled gem in 3.4, so it must be declared to remain loadable under Bundler.
- SimpleCov-based test coverage with substantially expanded tests across the suite.
- `IOStreams::Pgp.generate_key` now supports Elliptic Curve keys and passphrase-less key generation. New `key_curve`, `key_usage`, `subkey_curve`, `subkey_usage`, and `creation_date` options are accepted, and passing `passphrase: nil` generates an unprotected key. These features require GnuPG 2.1 or later; on older versions the new options raise a clear error while existing RSA-with-passphrase generation is unchanged.
- `IOStreams::Pgp::Reader` now accepts an `ignore_mdc_error:` option (default `false`). When enabled it passes `--ignore-mdc-error` to GnuPG so files lacking MDC (Modification Detection Code) integrity protection can be decrypted instead of failing with `gpg: decryption forced to fail!`. Some legacy/enterprise systems still produce such files. Only enable for files from a trusted source, since without MDC the decrypted contents are not protected against tampering.

### Security

- Hardened the HTTP path against Server-Side Request Forgery (SSRF).
- PGP security improvements, including clearer trust-level handling.

### Changed

- Fixed frozen string literal warnings and removed dead code.
- RuboCop adopted across the codebase (including `rubocop-minitest` and `rubocop-rake`), with a generated `.rubocop_todo.yml`.
- Documentation updates throughout.

## [1.11.0] - 2025-09-30

### Added

- Support for GnuPG v2.4.7.

### Changed

- Migrated PGP option from `:compression` to `:compress`.
- Declared the `csv` gem as a dependency for Ruby 3+.
- Dropped EOL Ruby versions from CI and updated CI actions; RubyGems sources now use HTTPS.

### Fixed

- Case-insensitive file matching for cross-platform CI compatibility.

## [1.10.3] - 2021-10-27

### Fixed

- Zip writer now returns the result of the block rather than the number of bytes compressed.

## [1.10.2] - 2021-10-25

### Changed

- Removed support for `#each` without a block (reverts the v1.10.0 behavior).
- Support string keys and types.

### Fixed

- PGP writer now returns the result of the block rather than the bytes copied.

## [1.10.1] - 2021-08-30

### Fixed

- Critical: do not signal EOF when the expected block size differs.

## [1.10.0] - 2021-08-23

### Added

- `#each` and `#each_child` return an Enumerator when no block is supplied.

## [1.9.0] - 2021-08-17

### Added

- `#remove_from_pipeline`.

## [1.8.0] - 2021-07-22

### Fixed

- Use of `nil` to identify rejected columns caused UI issues.

## [1.7.0] - 2021-06-23

### Added

- SFTP option to supply the host key explicitly, plus host-key tests.

### Changed

- Lazily load the S3 client, since constructing it can take a couple of seconds.

## [1.6.2] - 2021-05-04

### Fixed

- Give the remote SFTP server time to become ready to accept the password.

### Changed

- Updated links after the repository move.

## [1.6.1] - 2021-04-29

### Added

- Support for GnuPG v2.3.

### Fixed

- Return the key id when an email is not present for `import_and_trust`.

## [1.6.0] - 2021-03-08

### Removed

- Removed the deprecated API (initial deprecation pass).

### Added

- Allow a path to infer `#format` and to set it.

### Fixed

- AWS S3 files larger than 5 GB cannot be copied directly; handled accordingly.
- Handle missing delimiters in large files.

### Changed

- Make the Tabular default format an argument.
- Migrated CI to GitHub Actions.

## [1.5.1] - 2020-09-29

### Fixed

- Fixed extraneous arguments.

## [1.5.0] - 2020-09-10

### Added

- Support a "remainder" column as the last column with fixed-width parsing.

## [1.4.0] - 2020-09-04

### Changed

- Replaced `rbzip2` with `bzip2-ffi`.

## [1.3.3] - 2020-09-01

### Added

- Options for multipart S3 file uploads.

## [1.3.2] - 2020-08-31

### Added

- Support for Ruby 2.3.

### Changed

- Improved performance when handling thousands of CSV columns.

## [1.3.1] - 2020-07-16

### Fixed

- Fixed format does not use a header line.

## [1.3.0] - 2020-07-13

### Added

- Support parameters on HTTP GET.
- Usage of `IOStreams::Pgp` with keys that don't have an email address.

### Changed

- Switched to Amazing Print.
- Improved fixed-format handling.

### Fixed

- Ruby 2.7 warnings.

## [1.2.1] - 2020-05-19

### Fixed

- Consistent use of `original_file_name`.
- JSON format auto-detection.

## [1.2.0] - 2020-04-29

### Added

- Support encrypting a PGP file for multiple recipients.
- Backward-compatible deprecated `Pgp.has_key?`.

## [1.1.1] - 2020-04-04

### Added

- Support for gpg v2.2.19.

## [1.1.0] - 2020-02-24

### Added

- Override the temp file directory; create the supplied temp dir if not present.

### Fixed

- Matcher was incorrectly matching files in subdirectories.

## [1.0.0] - 2020-01-14

Major refactor that reduced the public API footprint to the `IOStreams` module plus the `Stream`/`Path` objects it returns.

### Added

- URI scheme-based `Path` subclasses for local file, S3, SFTP, and HTTP(S).
- `#move`, `#relative?`, and `#absolute?`.
- SFTP support, including key-based authentication (`IdentityKey`) and the Linux `sftp` executable.
- PGP streaming support via temp files.

### Changed

- Renamed the internal `Streams` pipeline builder to `Builder`.
- Use `:array` and `:hash` instead of `array`/`record`.
- Switched to the `zip_tricks` gem to read zip files.
- Moved deprecated methods into a separate mix-in.

## [0.20.3] - 2019-09-17

### Fixed

- File write error-recovery code.

## [0.20.2] - 2019-09-17

### Added

- Specify the entry name within a zip file to read.

## [0.20.1] - 2019-08-24

### Fixed

- New names for `path` and `root`.

## [0.20.0] - 2019-08-23

### Added

- PGP streaming support via temp files; next iteration of path support.

## [0.19.0] - 2019-08-22

### Added

- HTTP(S) file reader.

### Fixed

- Number-of-args issue for zip files.

## [0.18.0] - 2019-08-15

### Changed

- When writing files, create the path and clean up incomplete file writes.

## [0.17.3] - 2019-07-22

### Fixed

- Use binmode with Tempfiles.

## [0.17.2] - 2019-07-09

### Fixed

- Dependency loading for S3 (kept as a soft dependency).

## [0.17.1] - 2019-04-03

### Fixed

- S3 is a soft dependency and should not be required eagerly.

## [0.17.0] - 2019-04-03

### Added

- AWS S3 reader and writer.
- URI scheme support for paths.
- Embedded line support for line, record, and row readers.

## [0.16.2] - 2019-02-11

### Added

- Ruby 2.6 support.

## [0.16.1] - 2018-11-26

### Fixed

- Encoding cleansing could return fewer characters than requested.

## [0.16.0] - 2018-11-13

### Added

- Fixed-format support.
- Render a header directly.
- Load Symmetric Encryption if present.
- Turn xlsx files into a CSV stream.

### Changed

- Moved encoding into a separate stream.

### Removed

- Ruby 2.1 (EOL).

## [0.15.0] - 2018-10-02

### Added

- Introduced Tabular for processing streams.
- Row reader and record writer.
- Support for bzip2.
- Support for GnuPG v2.2.

### Removed

- Ability to export private keys.

## [0.12.1] - 2017-06-20

### Added

- Support for GnuPG v1.4 and v2.0.30.

## [0.12.0] - 2017-06-16

### Changed

- Refactored PGP methods to handle multiple keys and return extracted data.

## [0.11.0] - 2017-05-01

### Added

- `#encrypted?`.
- `IOStreams.copy_file`.

## [0.10.1] - 2017-03-28

### Fixed

- PGP writer error handling when the key is missing.

## [0.10.0] - 2016-09-27

### Added

- SFTP stream reader and writer.
- Read and write PGP/GPG encrypted files, with binary, compression, and compress-level options.

### Changed

- Ruby 2.1 is now the minimum, to fully support keyword arguments.
- Converted to named parameters.

## [0.9.1] - 2016-02-20

### Fixed

- Delimited reader `strip_non_printable` option.

## [0.9.0] - 2016-01-29

### Added

- Delimited and CSV readers and writers.

### Changed

- Xlsx reader now returns an Array instead of a CSV string.
- `.csv` is no longer registered by default.

## [0.8.2] - 2015-09-25

### Added

- Xlsx reader.

### Changed

- Switched the test suite to Minitest specs.

## [0.8.1] - 2015-08-27

### Fixed

- Also detect lone `\r` line terminators.

## [0.8.0] - 2015-08-25

### Added

- Delimited reader.
- Support for binary files; `encoding` can be passed as an option.

## [0.7.0] - 2015-07-13

Initial release as a standalone gem, extracted from the RocketJob streaming code.

### Added

- Stream-based readers and writers supporting daisy-chaining of multiple streams on a single source/destination.
- Streaming of zip, gzip, and encrypted files, plus user-definable formats.
- Compression and encryption for the streaming APIs.
- Copy from one stream to another, with custom options for any stream.

[2.0.0]: https://github.com/reidmorrison/iostreams/compare/v1.11.0...v2.0.0
[1.11.0]: https://github.com/reidmorrison/iostreams/compare/v1.10.3...v1.11.0
[1.10.3]: https://github.com/reidmorrison/iostreams/compare/v1.10.2...v1.10.3
[1.10.2]: https://github.com/reidmorrison/iostreams/compare/v1.10.1...v1.10.2
[1.10.1]: https://github.com/reidmorrison/iostreams/compare/v1.10.0...v1.10.1
[1.10.0]: https://github.com/reidmorrison/iostreams/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/reidmorrison/iostreams/compare/v1.8.0...v1.9.0
[1.8.0]: https://github.com/reidmorrison/iostreams/compare/v1.7.0...v1.8.0
[1.7.0]: https://github.com/reidmorrison/iostreams/compare/v1.6.2...v1.7.0
[1.6.2]: https://github.com/reidmorrison/iostreams/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/reidmorrison/iostreams/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/reidmorrison/iostreams/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/reidmorrison/iostreams/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/reidmorrison/iostreams/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/reidmorrison/iostreams/compare/v1.3.3...v1.4.0
[1.3.3]: https://github.com/reidmorrison/iostreams/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/reidmorrison/iostreams/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/reidmorrison/iostreams/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/reidmorrison/iostreams/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/reidmorrison/iostreams/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/reidmorrison/iostreams/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/reidmorrison/iostreams/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/reidmorrison/iostreams/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/reidmorrison/iostreams/compare/v0.20.3...v1.0.0
[0.20.3]: https://github.com/reidmorrison/iostreams/compare/v0.20.2...v0.20.3
[0.20.2]: https://github.com/reidmorrison/iostreams/compare/v0.20.1...v0.20.2
[0.20.1]: https://github.com/reidmorrison/iostreams/compare/v0.20.0...v0.20.1
[0.20.0]: https://github.com/reidmorrison/iostreams/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/reidmorrison/iostreams/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/reidmorrison/iostreams/compare/v0.17.3...v0.18.0
[0.17.3]: https://github.com/reidmorrison/iostreams/compare/v0.17.2...v0.17.3
[0.17.2]: https://github.com/reidmorrison/iostreams/compare/v0.17.1...v0.17.2
[0.17.1]: https://github.com/reidmorrison/iostreams/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/reidmorrison/iostreams/compare/v0.16.2...v0.17.0
[0.16.2]: https://github.com/reidmorrison/iostreams/compare/v0.16.1...v0.16.2
[0.16.1]: https://github.com/reidmorrison/iostreams/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/reidmorrison/iostreams/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/reidmorrison/iostreams/compare/v0.12.1...v0.15.0
[0.12.1]: https://github.com/reidmorrison/iostreams/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/reidmorrison/iostreams/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/reidmorrison/iostreams/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/reidmorrison/iostreams/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/reidmorrison/iostreams/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/reidmorrison/iostreams/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/reidmorrison/iostreams/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/reidmorrison/iostreams/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/reidmorrison/iostreams/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/reidmorrison/iostreams/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/reidmorrison/iostreams/releases/tag/v0.7.0
