# Changelog

All notable changes to this project are documented here.

This project adheres to [Semantic Versioning](https://semver.org/).

## [2.2.0] - Unreleased

v2.2 prepares applications for v3.0: it adds the methods that replace those that v3.0 deprecates or removes, so that
an application can move to them before it upgrades. What is deprecated still works as before: using it reports a Ruby
deprecation warning, which Ruby shows only while `Warning[:deprecated]` is on. It is off by default, but on in tests run
with Minitest or test-unit, which show the warnings on `$stderr`, including for the calls that another gem makes, such
as Rocket Job 7.0. Apart from these warnings, it changes no existing behavior, other than those under Changed and Fixed.

It adds `#schema`, which describes the rows and records of a file as v3.0 does, so that code that uses one keeps
working after an upgrade. Without a schema, files are read and written as before: the same results, exceptions and
internal interfaces.

### Added

- **`#raw` reads and writes the data as it is stored**, applying no streams, neither those that the file name implies nor any set with `#stream` or `#option`, and no encoding, for example to checksum a compressed file as it is stored, `Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").raw.read)`, or to write data that is already compressed, `IOStreams.path("data.csv.gz").raw.write(gzipped)`. Setting a stream, option or encoding after it raises `ArgumentError`, since the data is as stored. `#raw?` returns whether `#raw` was called. It replaces `stream(:none)`, which still works.
- **`#encoding` sets the encoding of the text that the application reads or writes**, and the other options of the encode stream, for example `IOStreams.path("export.csv").encoding("UTF-8", cleaner: :printable, replace: "")`. Unlike `option(:encode, ...)`, it keeps working after `#stream`, and for a stream without a file name, and unlike `stream(:encode, ...)`, it keeps the streams taken from the file name, so `IOStreams.path("data.csv.gz").encoding("BINARY")` is still decompressed. The encode stream is applied closest to the application, with the same options and the same results as `option(:encode, ...)`. Each call merges its options with those already set, `stream(:none)` and `remove_from_pipeline(:encode)` remove them, and an option that the encode stream does not take raises `ArgumentError`, as does a value that it does not accept, such as an encoding that Ruby does not know, or a `cleaner` that is neither the name of a built-in rule nor a Proc, when it is set, rather than once a writer has replaced the file. Without any arguments, `#encoding` returns the encoding that was set, or nil, like `IO#encoding`. It replaces `option(:encode, ...)` and `stream(:encode, ...)`, which still work.
- **`#schema` gives the type of each field of rows and records**, a [Frictionless Table Schema](https://datapackage.org/standard/table-schema/), as a Hash, or as the path or url of a JSON file in any store, which is read the first time that a reader or writer needs it. Reading rows and records with a schema returns each value as its type, `string`, `integer`, `number`, which is a `BigDecimal`, or a `Float` with `floatNumber: true`, `boolean`, `date`, `datetime`, `object`, which is a `Hash` read from the text of a JSON object, `array`, which is an `Array` read from the text of a JSON array, or `any`, and writing them writes each value in the text form of its type, for every format, with an `object` or an `array` as its JSON text, or in JSON as itself, and a `Hash` or an `Array` of an `any` field as JSON in a format of text, such as `{"a":1}`. JSON writes numbers and booleans as themselves, with all of the digits of a `number`, such as `12345678901234567.89`, and the digits after the decimal point that its `decimals` give, such as `12.50`, the same as CSV, rather than through a `Float`, including when ActiveSupport replaces how Ruby writes JSON, and reads them back with all of their digits, while the numbers of the other fields are still a `Float`. A `number` field accepts a `Rational`, which keeps every digit of a decimal that ends, and a fixed width file writes a number that is not finite, such as `NaN`, with spaces rather than zeros, so that it can be read back. A value that is not of the type of its field raises `IOStreams::Errors::InvalidValue`. A schema also gives the position of each field of a fixed width file, with the `width`, `start` and `truncate` of each field and the `width` of each line, which IOStreams adds to Frictionless, as it does `decimals`. The parts of Frictionless that IOStreams does not support yet, such as `primaryKey`, raise `ArgumentError`, rather than being ignored. An `integer` field also reads the text of a whole number with a decimal point, such as `12.0`, as a spreadsheet stores every number as a double. A `datetime` without an offset from UTC, or text in a `format` without a zone, is read as UTC, rather than in the time zone of the process. A `number` field needs the `bigdecimal` gem, which is a bundled gem from Ruby 3.4. The schema is held as it was set, a Hash or String as a frozen copy, so `#schema` returns it unchanged when the caller changes the Hash or String that it supplied. See [Schema](https://iostreams.reidmorrison.com/formats#schema).
- **The text of a file read with a schema is UTF-8.** Its values, and its lines read with `each(:line)`, are UTF-8 strings, rather than binary strings, so that its columns can be matched to the names of the fields in every language, and text that is not valid UTF-8 raises the new `IOStreams::Errors::InvalidEncoding`, which is an `Encoding::UndefinedConversionError`, naming the line that it is on, which its `#line_number` returns. An encoding set with `#encoding`, or the data read as it is stored with `#raw`, is taken as it is instead. Binary text written to the rows and records of a file with a schema, such as the values of a file without one that is copied, is written as UTF-8, unless it is not valid UTF-8 and an encoding is set with `#encoding`, which writes it instead, as it does without a schema, while lines written with `writer(:line)` are written as they are, as in IOStreams 3.0. Unlike IOStreams 3.0, a byte order mark is not removed, and a fixed width file counts the characters of its UTF-8 text, see [Schemas in IOStreams 2.2 and 3.0](https://iostreams.reidmorrison.com/formats#schemas-in-iostreams-22-and-30).
- **A schema with `header: false` describes a file without a header row**, whose columns are the fields of the schema, in order: reading takes every line as a row, and writing writes no header row. Since it is set on the path, every reader of the path reads the file that way, including `#copy_from` and `#copy_to`. `copy_from(source, mode: :array)` from such a file gives the target the names of the fields as the columns of its rows, so that a target with a header row, such as CSV, writes them as its header row, and one without, such as JSON, takes the keys of its records from them. A format without a header row, such as JSON or fixed width, ignores `header: false`. For a format with a header row, such as CSV, the columns of the file are then the fields in order, so a schema with `header: false` needs `fieldsMatch` `"exact"`.
- **A schema matches the columns of a file to its fields, and the keys of the records read are the names of its fields.** Each column of the header row, or key of a JSON record, is matched once to the field whose name it is, or whose `aliases` include it, otherwise to the field whose name or alias is the same once both are compared without their case, spaces and punctuation, with the forms of a character that Unicode treats as the same made the same, so that the field `first_name` matches the column `First Name`, and `email` matches `E-mail`, otherwise to the field whose name or alias is the same once both are cleansed as `cleanse_header` cleanses a header row, keeping the letters of every language, as IOStreams 3.0 cleanses one, so that the field `area_m` matches the column `Area (m²)`. `aliases` is a property that IOStreams adds to a field, for columns named another way, such as `["DOB", "Birth Date"]`. A column that could be two fields, or two columns that are one field, raise `IOStreams::Errors::InvalidHeader`, rather than guess or lose a value. Writing writes the names of the fields as the header row, in order, rather than the keys of the first record, and matches the keys of each record to the fields the same way, so that a file can have readable column names, such as `First Name`, while the code writes records whose keys are `first_name`. `writer(:array)` writes the header row itself, before the rows, as `writer(:hash)` does, and takes each row written as the values of the fields, in order. See [Matching columns to fields](https://iostreams.reidmorrison.com/formats#matching-columns-to-fields).
- **With a schema, `each(:array)` yields its header row as an `IOStreams::Row::HeaderRow`**, an Array that says that it is the header row, of the names of the fields of its columns, also for a file without a header row, such as fixed width or JSON, and `writer(:array)` with a schema takes one as the header row of the rows after it, whichever row it is, which it matches to the fields, so that the rows that `each(:array)` reads from a file with a schema can be written to another, whatever their formats. `copy_from(source, mode: :array)` and `copy_to` hand the target the header row of the source in the same way when either of them has a schema, also from a source without one, and skip the blank rows of the source. A target whose columns are supplied with `columns:` skips the header row, since its columns name the values of the rows instead, and a fixed width file with a layout in `#format_options` raises `IOStreams::Errors::InvalidHeader` for it, as it did for those rows before, rather than write blank values, since the layout does not match the columns of the header row to its keys: give it a schema instead. A copy between two files without a schema copies each row as before.
- **`fieldsMatch` says which columns a file with a schema can have, and must have**, as Frictionless defines it: `exact`, the default, the fields in order; `equal`, the fields in any order; `subset`, every field and other columns, which are skipped; `superset`, only fields, any of which can be missing; and `partial`, at least one field, and other columns, which are skipped. A file that does not match raises `IOStreams::Errors::InvalidHeader`, which lists each problem. It applies to the keys of each JSON record too, to the values of a row read after its last column, such as after a comma in a value that is not quoted, and when writing, to the keys of each record, the columns of the header row of the rows written, and the values of each row after its last column, which `subset` and `partial` skip. A value after the last column that is `nil`, or blank text, is not data, so it is ignored, and the columns without a name at the end of a header row are not columns. See [fieldsMatch](https://iostreams.reidmorrison.com/formats#fieldsmatch).
- **A field with `constraints: {required: true}` must have a value**, as Frictionless defines it: a header row or JSON record without the field raises `IOStreams::Errors::InvalidHeader`, whatever `fieldsMatch` is, and a value that is `nil`, or empty text, raises `IOStreams::Errors::InvalidValue`, when reading and when writing, including a blank record or row written, such as `{}`, while a blank row read is `nil`, as a blank line is. `allowBlank: true`, a property that IOStreams adds, lets a required field have blank values, while the header row, or each JSON record, must still have the field. The other constraints of Frictionless raise `ArgumentError`. See [Required fields](https://iostreams.reidmorrison.com/formats#required-fields).
- **With a schema, `columns:`, `allowed_columns:`, `required_columns:` and `cleanse_header:` raise `ArgumentError`**, since the schema describes the columns of the file on its path: its fields are the columns, `fieldsMatch` replaces `allowed_columns:` and `skip_unknown:`, and `constraints` replace `required_columns:`. A nil `columns:`, `allowed_columns:` or `required_columns:` is not supplied, and `skip_unknown:` only applies to `allowed_columns:`, so they are accepted, so that code, such as Rocket Job, can supply the same options with and without a schema. `cleanse_header: nil` still raises, since nil does not cleanse the header row. They raise before the file is opened. `schema:` supplied to each call of `#each`, `#reader` or `#writer` raises `ArgumentError`, since it is set on the path, and so does a schema with the layout of a fixed width file in `#format_options`, when a reader or writer of the path is created.
- **Using a deprecated method or option reports a Ruby deprecation warning**, which names the line of the application that used it, and what to use instead, such as `app/jobs/export_job.rb:12: warning: IOStreams: stream(:none) is deprecated, use #raw ...`, see Deprecated. It is reported with `Kernel#warn` in the `:deprecated` category, so Ruby only shows it while `Warning[:deprecated]` is true: not by default, so production stays quiet, but in tests run with Minitest or test-unit, or with `RUBYOPT=-W:deprecated`. Extend `Warning` with a `warn` of your own to send them elsewhere, such as to a log. What is deprecated still works as before. See [Seeing deprecation warnings](https://iostreams.reidmorrison.com/upgrading#seeing-deprecation-warnings).
- **`IOStreams.tabular_formats` returns the names of the formats that `#format` accepts**, such as `:csv`, `:json` and `:fixed`, so that an application can check a format held in configuration, or offer a choice of formats, without using the internal `IOStreams::Tabular.registered_formats`.

### Deprecated

Each still works as before, and reports a deprecation warning, see Added.

- **`stream(:none)`.** Use `#raw` to read or write the data as it is stored, see Added, or `#file_name` to read a file that is not named for its format, such as `file_name("data.csv")` for a CSV file named `data.txt`.
- **Setting the encode stream with `option(:encode, ...)`, `option_or_stream(:encode, ...)` or `stream(:encode, ...)`.** Use `#encoding` instead, see Added, which sets the same options, with the same results as `option(:encode, ...)`. `stream(:encode, ...)` still stops the streams being taken from the file name, like any other stream set with `#stream`, while `#encoding` keeps them: so to read or write the data as it is stored, as `stream(:encode, encoding: "BINARY")` does for a file name such as `data.csv.gz`, use `#raw`, and to read a file that is not named for its format, `#file_name`, then `#encoding`.
- **`format:`, `file_name:`, `original_file_name:` and `default_format:` supplied to each call** of `#each`, `#reader`, `#writer`, `#copy_from` or `#copy_to` in the `:array` or `:hash` mode, even when they are nil. They describe the file, so set the format on the path instead with `#format`, so that every reader and writer of the path uses it. A file name supplied to a call only chooses the format, when the path has none, and not the streams, as `#file_name` does, so set the format that it names, such as `format(:json)` for `file_name: "data.json"`, and `default_format:` only applies when the path has no format, so set it only then, such as `path.format(:json) unless path.format`. v3.0 raises `ArgumentError` for them.
- **`allowed_columns:`, `required_columns:` and `skip_unknown:` supplied to `#writer`, or to a copy**, which uses its options to write the target, even when they are nil. They only apply when reading, so a writer ignores them, and for example `copy_from(source, mode: :hash, allowed_columns: ["name"])` copies every column. Describe the columns that are written with `#schema` instead, such as with `fieldsMatch: "subset"`. v3.0 raises `ArgumentError` for them.
- **Options supplied to `#writer` when the stream is a line, row or record writer that is already open**, such as the one that `writer(:line)` yields, handed to `IOStreams.stream`, as in `IOStreams.stream(io).writer(:array, columns: ["name"])`. It writes with its own settings, so it ignores them: set them where that writer is opened, or remove them. v3.0 raises `ArgumentError` for them.
- **Options supplied to the `:stream` mode**, which is the default of `#reader` and `#writer`, to `#copy_from` and `#copy_to` without a `mode:`, and to a copy with `convert: false`, including `mode:`. Each of them ignores its options, so remove them. v3.0 raises `ArgumentError` for them.
- **The Zip writer's `zip_file_name`**, even when it is nil. Use `entry_file_name`, which also chooses the file to read within a zip file. v3.0 raises `ArgumentError` for it.
- **An option of `.bz2` that neither its reader nor its writer takes**, such as a misspelled one. BZip2 still ignores it, and logs a warning, as in v2.1, so remove it, since v3.0 raises `ArgumentError` for it. An option of the other direction, such as `block_size` when reading, is still logged, but is not reported as deprecated, since v3.0 accepts it, and ignores it.
- **A file name ending in `.encode`**, which applies the encode stream. File names do not name the encode stream, so set it with `#encoding` instead, after which the file name is not reported, since it adds nothing. v3.0 no longer applies it.
- **`#path=` and `#builder=`.** A path can be used by many objects at once, such as a root path that file names are joined to, so changing it in place changes it for all of them: use `#join` or `#directory`, or `IOStreams.path` with the new name. `#join` and `#directory` return a new path, created with the same arguments, such as the credentials of an SFTP path, but without the streams, options, format and schema set on this one, which `#path=` keeps, so set them again on the new path. `#builder=` takes an internal object: to start again without the streams and options set with `#stream` or `#option`, create the path again with `IOStreams.path`. Neither is public in v3.0.
- **`#format_options`, and `format_options:` supplied to each call.** Use `#schema`, see Added, which gives the `width` of each field of a fixed width file. `#format_options` still reads and writes the file with its layout, as before, and a schema with a layout raises `ArgumentError`. See [Moving a layout to a schema](https://iostreams.reidmorrison.com/upgrading#moving-a-layout-to-a-schema).
- **`columns:`, `allowed_columns:`, `required_columns:` and `skip_unknown:`, and `cleanse_header:`.** A schema describes the columns of the file on its path instead, see Added: its fields are the columns, in order, and with `header: false` the columns of a file without a header row, `fieldsMatch` says which other columns the file can have, and `constraints: {required: true}` which fields it must have. They still work without a schema, and report a deprecation warning unless they are nil, apart from `cleanse_header:`, which reports one even when it is nil, since nil does not cleanse the header row. With a schema, they raise `ArgumentError` instead, unless they are nil, apart from `cleanse_header:`, which raises even when it is nil, see Added, and `skip_unknown:`, which a schema accepts, where it has no effect, and which still reports a deprecation warning. Supplied to `IOStreams::Tabular`, as Rocket Job 7.0 does, they report nothing. `IOStreams.enforce_column_restrictions=` is not deprecated in v2.2, and still applies to them. See [Moving the column options to a schema](https://iostreams.reidmorrison.com/upgrading#moving-the-column-options-to-a-schema).
- **`embedded_within:` when reading rows and records.** The format of the file splits the lines of its rows and records, since its parser must agree with where they are split, so set the format with `#format` instead, such as `format(:psv)` for values that are not quoted. It is still the way to choose the lines that `each(:line)` returns.

### Changed

- **A failed copy no longer deletes a target that it did not write.** `#copy_from`, `#copy_to` and `#move_to` opened the target before the source, and deleted the target whenever the copy raised, so a copy from a source that does not exist, or with a mode that a copy does not convert with, deleted an existing target that it never wrote, and a failed copy to S3 deleted the existing object. The source is now opened first, as in v3.0, and an error raised before the target is opened, such as for a mode that a copy does not convert with, a schema file that does not exist, or a deprecation warning that the application's `Warning.warn` raises, leaves the target as it was. A copy that fails part way still leaves no part of the file: a local file is removed, as for any write that fails, and an S3 or SFTP file is only uploaded once the copy has written all of it, so an existing S3 object is kept. A mode that a copy does not convert with, such as `:stream`, now raises `ArgumentError` before the source or the target is opened, with a message that starts with v2.1's, `Invalid mode: :stream`, and then lists the modes. See [When a copy fails](https://iostreams.reidmorrison.com/copy_files#when-a-copy-fails).

### Fixed

- **A copy of a path or stream has its own streams, options and encoding.** Changing a copy made with `dup`, such as with `#option`, `#encoding` or `#raw`, no longer changes the path that it was copied from, and `#copy_from` and `#copy_to` with `convert: false`, and `#move_to`, no longer change the streams of the source or the target. In v2.1, once the settings of a path had been read, such as with `#pipeline`, a copy with `convert: false` left it reading and writing the data as it is stored. A copy with `convert: false` from a source with options set with `#option` now copies it, where v2.1 raised `ArgumentError`.

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
