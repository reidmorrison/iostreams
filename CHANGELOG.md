# Changelog

All notable changes to this project are documented here.

This project adheres to [Semantic Versioning](https://semver.org/).

## [3.0.0] - Unreleased

### Breaking

These changes were postponed from v2.1, where each one logged a warning via `IOStreams.logger` when it would change the result.

- **`allowed_columns`, `required_columns` and `skip_unknown` now apply to every input when reading records.** `IOStreams.enforce_column_restrictions` now defaults to true. Previously they were only applied to a header row read from the file, and only when `cleanse_header` was true, so they were ignored for JSON and `:hash` input, when `columns:` was supplied, and with `cleanse_header: false`. Since the format is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypassed the allow list. When either `allowed_columns` or `required_columns` is set, JSON keys are now cleansed like a header row (for example `"Name"` becomes `"name"`), unknown keys are skipped or raise `IOStreams::Errors::InvalidHeader`, and a record missing a required column raises `IOStreams::Errors::InvalidHeader`. Set `IOStreams.enforce_column_restrictions = false` to keep the previous behavior.
- **BZip2 options are strict.** The BZip2 reader and writer now raise `ArgumentError` for an option they do not accept, like every other stream, instead of ignoring it. They accept `autoclose`, `first_only` and `small` when reading, and `autoclose`, `block_size` and `work_factor` when writing.
- **`IOStreams::Pgp.export(email: nil)` without a `key_id:` raises `ArgumentError`** instead of `IOStreams::Pgp::Failure`.

These bug fixes change behavior that existing code may depend on:

- **`allowed_columns`, `required_columns` and `skip_unknown` now also apply when reading rows** with `each(:array)`: to the supplied `columns:`, and to the header row with `cleanse_header: false`. Previously they were ignored in both cases, as they were when reading records. The header row is still yielded as it was read, and each row still contains every value. Set `IOStreams.enforce_column_restrictions = false` to keep the previous behavior, which logs a warning when applying them would change the header row.
- **PGP email addresses match exactly.** An email address now only matches keys with exactly that email address, ignoring case, for the writer's `recipient` and `signer`, and the `email:` argument of `IOStreams::Pgp.list_keys`, `key?`, `export`, `delete_keys` and `set_trust`. gpg treats a bare email address as a search for any user id containing it, so `delete_keys(email: "bob@example.com")` also deleted the keys for `jimbob@example.com` and `bob@example.com.attacker.net`, `set_trust(email:)` could trust one of those keys instead, and when the key for the recipient was missing, the file was encrypted to one of those keys instead of failing.
- **Reading gzip returns every member.** Reading a gzip file that contains several members, for example gzip files that were concatenated, returns the contents of every member, as `gunzip` does. Previously only the first member was returned, without an error. Zero bytes after the last member are ignored. The stream supplied to the block when reading gzip is no longer a `Zlib::GzipReader`; it responds to `#read`, `#readpartial` and `#eof?`, like the other streams.
- **The `:encode` stream keeps valid characters, and validates every read.** It keeps valid characters in data read from a file. Data read from a file has no encoding, so it was converted from binary, where every byte above 127 is undefined: with `replace:`, for example `option(:encode, encoding: "UTF-8", replace: "")`, every non-ASCII character was removed, turning `José` into `Jos`, and without it, reading a whole file raised `Encoding::UndefinedConversionError` for any non-ASCII character. Binary data is now treated as already being in the requested encoding, so only invalid characters are replaced, or raise `Encoding::UndefinedConversionError`, when reading and when writing. Previously reading lines let invalid characters through without raising. A multi-byte character split across two blocks is kept, where previously reading lines could raise `ArgumentError: invalid byte sequence in UTF-8` for files over 64KB. The encode reader also accepts the buffer argument of `IO#read`, so that `#copy_from` and `#copy_to` with an encode stream no longer raise `ArgumentError`, and each read returns a new string.
- **A `+` in an S3 or SFTP url is kept.** `IOStreams.path("s3://bucket/a+b.csv")` now reads the key `a+b.csv`. Previously the path of an S3 or SFTP url was decoded like a query string, so a `+` became a space and it read the key `a b.csv`. Use `%20` or a space for a space.
- **Local `#each_child` and `IOStreams.each_child` honor `case_sensitive:` on every platform.** On a case-sensitive file system, such as on Linux, the default `case_sensitive: false` was ignored unless nothing matched, so `"r*.md"` did not return `README.md`, and `"*.csv"` did not return `DATA.CSV` when `data.csv` was also present. On a case-insensitive file system, such as on macOS, `case_sensitive: true` was ignored, so `"*.CSV"` returned `data.csv`.
- **The file within a zip file written to a path is named after the path.** Writing `example.csv.zip`, or `example.csv.zip.pgp`, now names the file within the zip file `example.csv`, as documented. Previously it was named `file`, unless `entry_file_name:` was supplied.
- **A hash key that matches a column once cleansed supplies its value.** When writing a hash with `columns:`, or reading JSON or `:hash` records with `columns:`, a column without a key of the same name now takes the value of the key that is the same once both are cleansed like a header row, so the key `"First Name"` supplies the column `first_name`. Previously the column was always empty, so for example `writer(:hash, columns: ["first_name"])` wrote an empty field for `{"First Name" => "Jack"}`. A key that matches the column exactly is still used first.

### Fixed

- Chaining `<<` when writing arrays or hashes, for example `io << row1 << row2` within `writer(:array)` or `writer(:hash)`, writes each row. Previously `<<` returned the underlying line writer, so every row after the first in a chain was written as its Ruby `inspect` output, such as `{"name" => "Jill"}`.
- `IOStreams.each_child` with a pattern that has no directory, such as `IOStreams.each_child("*.csv")`, searches the current directory. Previously it searched the root directory `/`, so `"**/*.csv"` searched the entire file system.
- `IOStreams.temp_file` runs the block once. Previously, when the block raised `Errno::EEXIST`, for example from `Dir.mkdir`, the block was run again with a new file name up to 5 times, and then a `RuntimeError` was raised instead. It also no longer chooses the name of a file that already exists, which it then deleted when the block finished.
- S3 `#each_child` only returns children within the path. Previously it listed every key starting with the same characters, so `IOStreams.path("s3://bucket/reports").each_child("*.csv")` also returned `s3://bucket/reports_x.csv`, and `"**/*.csv"` returned files in `reports_2024/`. It also no longer parses the path as a URL, so a path containing `+` or `%`, for example one built with `#join`, lists its children instead of none or raising `URI::InvalidURIError`, and the children keep the options of the path, such as `request_payer`.
- `#join` and `#directory` on HTTP and SFTP paths change the url. Previously only `#path` changed, so `IOStreams.path("https://example.com/files").join("report.csv").read` downloaded `https://example.com/files`, allowed paths were checked against that url, and `#to_s` of a joined SFTP path returned the original url. Characters in an HTTP path that cannot appear in a url, such as a space, `?` or `#`, are percent-encoded in the url.
- A failed `#copy_from` or `#copy_to` no longer deletes an existing target. Previously the target was opened, emptying a local file, before the source was opened, so copying from a missing source deleted the target, and when any copy to S3 failed the existing object, which is only replaced once the upload completes, was deleted. The source is now opened first, and only a target that did not exist before the copy is removed when the copy fails.
- Reading a PGP file no longer hangs when the block returns before reading the whole file, for example `reader(:line, &:readline)` or `reader { |io| io.read(10) }` on a file larger than the pipe buffer. The rest of the file is now decrypted and checked by gpg before the result is returned.
- The `:printable` and `:replace_non_printable` cleaners of the `:encode` stream no longer change the string supplied to the writer when writing binary data, for example with `encoding: "ASCII-8BIT"`, which also raised `FrozenError` for a frozen string.
- Reading a CSV file with an unbalanced quote no longer takes quadratic time when the data is read as UTF-8 through an encode stream. The size of such a line is now limited in bytes rather than characters.
- Copying between S3 paths with `convert: false`, or with `#move_to`, copies a key that contains a space, `+`, `%`, `?` or another character that must be url-encoded. Previously the key was not url-encoded, which S3 requires, so the copy failed or copied another object.
- The format of a file is detected from an upper case extension, so `DATA.JSON` is read as JSON. Previously it was read as CSV, the default. The format and the streams are also no longer detected from the name of the file before its first `.`, or from a directory name: previously `hash.txt` was read as the `:hash` format, a file named `gz` was read as gzip, and `reports.json/data.txt` was read as JSON.
- Local `#each_child` returns the children of a directory whose name contains a pattern character such as `[`, `{`, `*` or `?`. Previously it returned nothing, or the children of other directories. Within the pattern itself such characters must still be escaped with `\`. It also no longer yields the directory itself, as `dir/.`, with `hidden: true` and `directories: true`.
- `#copy_from` and `#copy_to` with `convert: false` no longer change the streams of the source or target path. Previously both paths were left with no streams, as with `stream(:none)`, so for example a later `#read` of a `.gz` source returned its compressed data, and a source with an `#option` raised `ArgumentError`.
- `IOStreams::Pgp.list_keys` returns `[]` for an empty keyring, instead of raising `IOStreams::Pgp::Failure`, and `IOStreams::Pgp.pgp_version` raises `IOStreams::Pgp::Failure` with gpg's error when `gpg --version` fails, instead of `NameError`.
- `IOStreams::Pgp.import` returns the name of a key whose user id has no email address, with a `nil` email. Previously it returned the name `"Joe Bloggs"` and the email address `"pgp_test@iostreams.net"`, values left over from its tests, for such a key, and for a key whose user id it could not read.
- Reading a zip file whose first entry is a folder reads the first file in it. Previously it raised `NoMethodError`.
- `#move_to` from S3 to a path that is not on S3, such as a local file, returns the target path. Previously it returned the number of bytes copied.

## [2.1.0] - 2026-10-04

### Breaking

- **`IOStreams::Pgp.delete_keys` requires an `email:` or `key_id:`.** Calling it with neither now raises `ArgumentError`. Previously, on GnuPG 2.1 and later, it deleted every key in the keyring (and with `private: true`, every secret key). To delete several keys, call it once per email or key id, for example for each key returned by `IOStreams::Pgp.list_keys`. This is the only breaking change in this release, since deleting the keyring cannot be undone.

### Deprecated

These changes would break existing code, so they are postponed to v3.0. Each one logs a warning via `IOStreams.logger` when it would change the result.

- **`allowed_columns`, `required_columns` and `skip_unknown` will apply to every input when reading records.** They are only applied to a header row read from the file, and only when `cleanse_header` is true, so they are ignored for JSON and `:hash` input, when `columns:` is supplied, and with `cleanse_header: false`. Since the format is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypasses the allow list. Set `IOStreams.enforce_column_restrictions = true` to apply them to every input now. JSON keys are then cleansed like a header row (for example `"Name"` becomes `"name"`), unknown keys are skipped or raise `IOStreams::Errors::InvalidHeader`, and a record missing a required column raises `IOStreams::Errors::InvalidHeader`.
- **BZip2 options will be strict.** The BZip2 reader and writer ignore any option that `bzip2-ffi` does not use, and now log a warning. In v3.0 it will raise `ArgumentError`, like every other stream. They accept `autoclose`, `first_only` and `small` when reading, and `autoclose`, `block_size` and `work_factor` when writing.
- **`IOStreams::Pgp.export(email: nil)` without a `key_id:` will raise `ArgumentError`** instead of `IOStreams::Pgp::Failure`.

### Added

- **Allowed paths** restrict IOStreams to accessing only paths within the supplied paths, for example `IOStreams.add_allowed_path("/var/data/uploads")` in an initializer. Once any allowed path is added, reading, writing, listing, deleting or otherwise accessing any other path raises `IOStreams::Errors::AccessDenied`, so an untrusted file name cannot be used to access other files. Local file names are compared by their real path, so `..` and symbolic links cannot be used to leave an allowed path. S3 paths must be in the same bucket, and keys containing `.` or `..` segments are denied since some services that implement the S3 API resolve them. SFTP and HTTP paths must have the same host and port (and scheme for HTTP), with `.` and `..` resolved as the server resolves them, and an HTTP redirect outside the allowed paths is also denied. `#each_child` skips children outside the allowed paths, and temp files from `IOStreams.temp_file` are always accessible. Also adds `IOStreams.delete_allowed_path`, `IOStreams.allowed_paths` and `IOStreams.allowed_path?`. Nothing changes until an allowed path is added. Paths from a scheme registered with `IOStreams.register_scheme` are denied once allowed paths are added, unless their path class implements the private method `#allowed_location`.
- The PGP reader accepts a `verify_first` option, for example `option(:pgp, passphrase: "secret", verify_first: true)`. It decrypts the whole file into a temporary file that only the current user can read, and only passes the contents to the block once gpg has checked the file's integrity and signature. By default the contents are passed to the block as they are decrypted, before those checks complete, which is now documented.
- `IOStreams.enforce_column_restrictions=` applies `allowed_columns`, `required_columns` and `skip_unknown` to every input when reading records, including JSON records, supplied `columns:` and `cleanse_header: false`. It defaults to false, and will default to true in v3.0. See Deprecated above.
- `IOStreams::Pgp.export` accepts `key_id:` as an alternative to `email:`.
- The GZip writer accepts a `level` option to set the compression level, for example `option(:gz, level: 9)`. Previously any option raised `ArgumentError`.

### Changed

- The `ArgumentError` for an option supplied to a stream now says what is wrong. When the option only applies in the other direction, for example `option(:enc, compress: false)` when reading, the message names the direction it belongs to and suggests configuring a separate path for reading. Otherwise it lists the valid options. Previously the error was Ruby's `unknown keyword`, raised from inside the gem that implements the stream. See [#38](https://github.com/reidmorrison/iostreams/issues/38).

### Security

- PGP: the writer's `import_and_trust_key` option now encrypts to the imported key's fingerprint, on GnuPG 2.1 and later. Previously it encrypted to the key's email address, which gpg looks up in the keyring, so another key with the same email address could be used instead. When a key has several user ids, `import_and_trust` now also trusts the key by its fingerprint instead of looking up its last email address.
- SFTP: a `username:` starting with `-` could be read by the `sftp` executable as an option, for example `-D` to run a local command. The destination is now preceded by `--`, and usernames that start with `-` or contain control characters raise `ArgumentError`.
- PGP: email addresses and key ids are now preceded by `--` when passed to `gpg`, so a value such as `--comment=x@example.com` can no longer be read as an option (which matched every key in the keyring).
- PGP: `set_trust(key_id:)` raises `ArgumentError` unless the key id is only hexadecimal digits. It is written into the input of `gpg --import-ownertrust`, where a newline could add trust lines for other keys, for example to give an attacker's key ultimate trust.
- PGP: the signer passphrase and the `export(passphrase:)` passphrase are now supplied to `gpg` on a file descriptor instead of the command line, so they are no longer visible in the process list.
- Internal temp files, which can hold decrypted data such as the plaintext of a `.zip.pgp` file, are now created with mode `0600`, and a new name is chosen rather than reuse an existing file or link.
- S3 and SFTP `#each_child` no longer reparse remote file names as URLs, so a name containing `?`, `+` or `%` can no longer change the child path or add S3 request parameters.
- SFTP `#each_child` now requires a known host key, matching the `sftp` executable's `StrictHostKeyChecking=yes`, instead of trusting a host key the first time it is seen.
- Credentials are no longer included in HTTP error messages, in the `sftp` output included in SFTP errors, or in the passphrase options displayed by `Path#inspect`.
- Removed an unused line that merged the SFTP URL query string into the ssh options. It currently had no effect, but would have allowed options such as `?ProxyCommand=...` to run commands if it were ever fixed.
- Reading a CSV file with an unbalanced quote no longer takes quadratic time.
- Documented that a username and password supplied in an HTTP or SFTP url are returned by `#to_s`, and recommended supplying them with the `username:` and `password:` arguments instead.
- Documented that an S3 URL query string is added to the S3 request parameters, and that untrusted file names should be added with `#join` rather than interpolated into the URL.

### Fixed

- S3 `#each_child` returns children that use the same client as the path, so they keep its credentials and region. Previously each child created a client from the default AWS configuration.
- `Path#join` and `IOStreams.join` only return an element unchanged when it is the path itself or is inside it. Previously any element that merely started with the same characters was returned as-is, so `IOStreams.path("s3://bucket/reports").join("reports_2024.csv")` gave `s3://bucket/reports_2024.csv` instead of `s3://bucket/reports/reports_2024.csv`, and with a root of `/data/uploads`, `join("/data/uploads_other/secret.csv")` escaped the root. Elements containing `..` are still joined as supplied.
- SFTP `#each_child` supports the `HostKey`, `IdentityKey`, `IdentityFile`, `UserKnownHostsFile`, `StrictHostKeyChecking`, `ConnectTimeout`, `ServerAliveInterval`, `ServerAliveCountMax` and `LogLevel` ssh options, using them the same way as reading and writing. Previously supplying any `ssh_options` made it raise `ArgumentError: invalid option(s)` from net-ssh. Any other ssh option now raises an `ArgumentError` that lists the supported options. It also uses only the password when one is supplied, otherwise only public keys, and never prompts for input, like reading and writing.
- SFTP `#each_child` lists the files in the path's directory. Previously it ignored the path and listed the login directory, returning children with paths relative to the root directory, so `IOStreams.path("sftp://host/data/in").each_child("*.csv")` listed `~/*.csv` as `/a.csv`. A url without a path, such as `sftp://host`, still lists the login directory. Children also keep the url's port, instead of using port 22.
- SFTP reading and writing without a password, for example with `IdentityFile`, no longer requires the `sshpass` program, as documented. Previously `sftp` was always run via `sshpass`, and every download waited 7 seconds (`before_password_wait_seconds` and `sshpass_wait_seconds`) for a password prompt, even without a password.
- When reading lines, newlines within quoted values are kept within the line when the tabular format quotes its values, such as CSV. Previously this depended on whether the file name contained `.csv`, so `.format(:psv)` on a `.csv` file still joined quoted lines, raising "Unbalanced delimited field" for a value such as `O"neil`, and `.format(:csv)` on a stream without a file name split quoted values at their newlines. Pass `embedded_within: nil` to disable it.
- When writing PSV or fixed width files, line breaks within a value are now replaced with a space. Previously a value such as `"Jack\nFORGED"` wrote a separate record. PSV already replaced `|` with `:` for the same reason.

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

[2.1.0]: https://github.com/reidmorrison/iostreams/compare/v2.0.0...v2.1.0
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
