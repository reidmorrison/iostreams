# Changelog

All notable changes to this project are documented here.

This project adheres to [Semantic Versioning](https://semver.org/).

## [3.0.0] - Unreleased

### Breaking

Text is read as UTF-8 by default:

- **Lines, rows and records are UTF-8 strings.** Reading with `#each`, or `#reader` in the `:line`, `:array` or `:hash` mode, decodes the data with the encode stream and its default options, unless an encoding is set with `#encoding`, so the strings are UTF-8, and data that is not valid UTF-8 raises `Encoding::UndefinedConversionError`. Previously they were binary (`ASCII-8BIT`) strings, apart from values parsed from JSON, which could not be combined with UTF-8 text: for example, writing a CSV row that mixed a value read from a file with a non-ASCII UTF-8 value raised `Encoding::CompatibilityError`, and a column name with a non-ASCII character, read with `cleanse_header: false`, did not match the same UTF-8 string. The values of a spreadsheet were also binary, although they are UTF-8 in the file. Fixed width files are read as ASCII instead, see below. To read binary strings as before, supply `encoding("BINARY")`, and for another encoding, such as Windows-1252, supply it to `#encoding`. `#raw` reads and writes the data as it is stored, as bytes, see Added.
- **A UTF-8 byte order mark at the start of the data is removed** when reading lines, rows or records, or reading through an encode stream with `encoding: "UTF-8"`. Excel writes one at the start of a "CSV UTF-8" file, so reading such a file with a quoted header row raised `CSV::MalformedCSVError: Illegal quoting`, and with `cleanse_header: false` its first column name began with the byte order mark (U+FEFF). `#read` keeps it, like `File.read`.
- **`#read` returns the whole file as UTF-8, without checking it, like `File.read`.** A binary file, such as an image, can still be read, since its bytes are unchanged. Previously it was binary, apart from `.gz` and `.enc` files, which were in `Encoding.default_external`, so their encoding depended on the locale. An IO that you supply, read without any streams, keeps the encoding that it gives its data, and with an encode stream the data is in the stream's encoding, and checked. `#read` with a length, such as `read(1024)`, the `:stream` mode, and writing still read and write bytes.

These changes were postponed from v2.1, where each one logged a warning via `IOStreams.logger` when it would change the result.

- **Fixed width files are read and written as ASCII by default.** Reading or writing rows or records with `format: :fixed`, or lines when the format of the path is `:fixed`, uses the encode stream with `encoding: "US-ASCII:UTF-8"`, unless an encoding is set with `#encoding`, or the data is read as stored with `#raw`; other encode options, such as `replace:`, are kept. Their sizes count bytes, and their text is ASCII or a single-byte code page, so the values read are UTF-8 strings, and a byte that is not ASCII raises `IOStreams::Errors::InvalidEncoding`, naming the byte and its offset, where previously the values were binary strings. Writing a value that is not ASCII raises `Encoding::UndefinedConversionError`, where previously its UTF-8 bytes were written, making the line longer than the layout in bytes. Set the encoding of the file instead, such as `encoding("ISO-8859-1:UTF-8")`, `"IBM037:UTF-8"` for EBCDIC, or `"UTF-8"` for UTF-8 written by a program that counts characters, or supply `replace: " "` to replace each character that is not ASCII with a space.
- **Cleansing a header row keeps letters and digits that are not ASCII.** Now that the header row is read as UTF-8, the column `Prénom` is cleansed as `prénom`, and `日付` as `日付`, where they were `prnom` and an empty name, since `\W` only matches ASCII, so columns such as `日付` and `金額` had the same empty name. JSON keys are cleansed the same way when they are matched to columns. Whitespace that is not ASCII, such as a no-break space, is converted to `_` and stripped like a space, so `First Name` with a no-break space is `first_name`, where it was `firstname`. Rename any `allowed_columns`, `required_columns` or `columns` written to match the previous names, such as `prnom`.

- **`allowed_columns`, `required_columns` and `skip_unknown` now apply to every input when reading records.** `IOStreams.enforce_column_restrictions` now defaults to true. Previously they were only applied to a header row read from the file, and only when `cleanse_header` was true, so they were ignored for JSON and `:hash` input, when `columns:` was supplied, and with `cleanse_header: false`. Since the format is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypassed the allow list. When either `allowed_columns` or `required_columns` is set, JSON keys are now cleansed like a header row (for example `"Name"` becomes `"name"`), unknown keys are skipped or raise `IOStreams::Errors::InvalidHeader`, and a record missing a required column raises `IOStreams::Errors::InvalidHeader`. Set `IOStreams.enforce_column_restrictions = false` to keep the previous behavior.
- **BZip2 options are strict.** The BZip2 reader and writer now raise `ArgumentError` for an option that neither of them accepts, like every other stream, instead of ignoring it. They accept `autoclose`, `first_only` and `small` when reading, and `autoclose`, `block_size` and `work_factor` when writing, and each ignores the options of the other.
- **`IOStreams::Pgp.export(email: nil)` without a `key_id:` raises `ArgumentError`** instead of `IOStreams::Pgp::Failure`.

This option is removed:

- **The Zip writer no longer accepts `zip_file_name`.** Use `entry_file_name`, which the documentation has used in its place for a long time, and which also chooses the file to read within a zip file. `option(:zip, zip_file_name: "a.csv")` now raises `ArgumentError`.

These changes affect code that registers extensions, or reads them with `IOStreams.extensions`:

- **`IOStreams.extensions` returns the format registered for each extension**, such as `IOStreams::Gzip` for `:gz`, instead of an `IOStreams::Extension` struct. A format answers `reader_class` and `writer_class` as before, and also `compressed?` and `encrypted?`, but not the methods of a struct, such as `to_a`, `to_h`, `==` or `[]`. An extension registered with its reader and writer classes is still an `IOStreams::Extension`, which is now frozen, so its setters, such as `writer_class=`, raise `FrozenError`. Previously the setters changed the registered extension for the whole process, since `IOStreams.extensions` returns a copy of the registry that shares its entries.
- **The `:encode` stream is built in, rather than a registered extension.** It converts the text that the application reads or writes, rather than the data of a file format, so `IOStreams.extensions` no longer includes it, `IOStreams.register_extension(:encode, ...)` raises `ArgumentError`, since `:encode` is a reserved keyword, instead of replacing it, and `IOStreams.deregister_extension(:encode)` returns `nil`. It is applied with `#encoding`, see Added, and still with `#option` or `#stream`, as before.
- **`:none` cannot be registered as an extension.** It is a reserved keyword, which `#stream` takes to apply no streams, so `IOStreams.register_extension(:none, ...)` raises `ArgumentError`. Previously it registered a stream that `stream(:none)` could not apply.
- **An extension registered with just its reader and writer classes is neither compressed nor encrypted.** So after replacing a built-in extension that is, such as `:xlsx`, `:gz` or `:pgp`, with your own reader and writer classes, `#compressed?` or `#encrypted?` is now `false` for its files, where previously both were based on the file name. Register a format that answers `compressed?` or `encrypted?` to keep them `true`.

These bug fixes change behavior that existing code may depend on:

- **`allowed_columns`, `required_columns` and `skip_unknown` now also apply when reading rows** with `each(:array)`: to the supplied `columns:`, and to the header row with `cleanse_header: false`. Previously they were ignored in both cases, as they were when reading records. The header row is still yielded as it was read, and each row still contains every value. Set `IOStreams.enforce_column_restrictions = false` to keep the previous behavior, which logs a warning when applying them would change the header row.
- **PGP email addresses match exactly.** An email address now only matches keys with exactly that email address, ignoring case, for the writer's `recipient` and `signer`, and the `email:` argument of `IOStreams::Pgp.list_keys`, `key?`, `export`, `delete_keys` and `set_trust`. gpg treats a bare email address as a search for any user id containing it, so `delete_keys(email: "bob@example.com")` also deleted the keys for `jimbob@example.com` and `bob@example.com.attacker.net`, `set_trust(email:)` could trust one of those keys instead, and when the key for the recipient was missing, the file was encrypted to one of those keys instead of failing.
- **Reading gzip returns every member.** Reading a gzip file that contains several members, for example gzip files that were concatenated, returns the contents of every member, as `gunzip` does. Previously only the first member was returned, without an error. Zero bytes after the last member are ignored. The stream supplied to the block when reading gzip is no longer a `Zlib::GzipReader`; it responds to `#read`, `#readpartial` and `#eof?`, like the other streams.
- **The `:encode` stream keeps valid characters, and validates every read.** It keeps valid characters in data read from a file. Data read from a file has no encoding, so it was converted from binary, where every byte above 127 is undefined: with `replace:`, for example `option(:encode, encoding: "UTF-8", replace: "")`, every non-ASCII character was removed, turning `José` into `Jos`, and without it, reading a whole file raised `Encoding::UndefinedConversionError` for any non-ASCII character. Binary data is now treated as already being in the requested encoding, so only invalid characters are replaced, or raise `Encoding::UndefinedConversionError`, when reading and when writing. Previously reading lines let invalid characters through without raising. With `replace:`, the sizes of fixed width columns read through the encode stream as UTF-8 now count characters, as they already did without it, where they counted bytes, since each byte of a non-ASCII character was replaced. A multi-byte character split across two blocks is kept, where previously reading lines could raise `ArgumentError: invalid byte sequence in UTF-8` for files over 64KB. The encode reader also accepts the buffer argument of `IO#read`, so that `#copy_from` and `#copy_to` with an encode stream no longer raise `ArgumentError`, and each read returns a new string. Data read is treated as bytes whichever streams it was read through, so reading the whole of a `.gz` or `.enc` file is no longer converted from `Encoding.default_external` first, which, for example, made `option(:encode, encoding: "Windows-1252").read` raise for a Windows-1252 `.gz` file but not for the same data in a plain file.
- **Writing PGP to an IO streams the encrypted data into it.** Writing PGP to an IO supplied to `IOStreams.stream`, such as a `StringIO`, a socket, or a `File`, now writes the encrypted data to it as it is written, instead of copying it there from a temp file once the block completes. So when the block raises, or `gpg` fails, the IO holds the start of a PGP message, which reading raises `IOStreams::Pgp::Failure` for, where previously nothing was written to it. A local path still removes its partial file. The stream supplied to the block when writing PGP, or when reading PGP from an IO that is not a local file, is no longer an `IO`; like the other streams, it responds to `#write`, `#<<`, `#print`, `#puts` and `#printf` when writing, and to `#read`, `#readpartial`, `#gets`, `#each_line` and `#eof?` when reading.
- **A `+` in an S3 or SFTP url is kept.** `IOStreams.path("s3://bucket/a+b.csv")` now reads the key `a+b.csv`. Previously the path of an S3 or SFTP url was decoded like a query string, so a `+` became a space and it read the key `a b.csv`. Use `%20` or a space for a space.
- **A `%`, `?` or `#` in an S3 or SFTP name is percent-encoded in `#to_s`**, as `%25`, `%3F` or `%23`, so that the path can be created again from its url. For example the file `a#b.csv`, found by `#each_child` or joined to a path, is `sftp://host/data/a%23b.csv`, where it was `sftp://host/data/a#b.csv`, which is the file `/data/a` when created again, so that an application that stored the url read or wrote another file. `#path` and `#basename` are unchanged.
- **The `#path` of an HTTP(S) url is decoded**, like S3 and SFTP paths, so `IOStreams.path("https://example.com/my%20file.csv").path` is `/my file.csv`, and `#basename` is `my file.csv`. Previously it was percent-encoded, as `/my%20file.csv`, unlike S3 and SFTP paths, and unlike a path from `#join`, which was not encoded. `#to_s` is unchanged. A url without a path, such as `https://example.com`, has the path `/`, where it was empty.
- **An SFTP or HTTP(S) url without a path ends with `/`**, like the root of an S3 bucket, `s3://bucket/`. `IOStreams.path("sftp://host").to_s` is now `sftp://host/`, and `IOStreams.path("https://host?a=1").to_s` is `https://host/?a=1`. Previously the url was returned as supplied, so `IOStreams.path("sftp://host")` was not equal to `IOStreams.path("sftp://host/")`, or to its own `#directory`, and they were different `Hash` keys, although they are the same location.
- **A direct copy between S3 paths returns the number of bytes copied**, like every other copy. `#copy_from` with `convert: false` from another S3 path returned the response from the `copy_object` call, and `#copy_to` with `convert: false` to another S3 path returned the target path. Copying between S3 paths with conversions, or with any other path, already returned the number of bytes. `#move_to` still returns the target path.
- **Local `#each_child` and `IOStreams.each_child` honor `case_sensitive:` on every platform.** On a case-sensitive file system, such as on Linux, the default `case_sensitive: false` was ignored unless nothing matched, so `"r*.md"` did not return `README.md`, and `"*.csv"` did not return `DATA.CSV` when `data.csv` was also present. On a case-insensitive file system, such as on macOS, `case_sensitive: true` was ignored, so `"*.CSV"` returned `data.csv`.
- **The file within a zip file written to a path is named after the path.** Writing `example.csv.zip`, or `example.csv.zip.pgp`, now names the file within the zip file `example.csv`, as documented. Previously it was named `file`, unless `entry_file_name:` was supplied.
- **A hash key that matches a column once cleansed supplies its value.** When writing a hash with `columns:`, or reading JSON or `:hash` records with `columns:`, a column without a key of the same name now takes the value of the key that is the same once both are cleansed like a header row, so the key `"First Name"` supplies the column `first_name`. Previously the column was always empty, so for example `writer(:hash, columns: ["first_name"])` wrote an empty field for `{"First Name" => "Jack"}`. A key that matches the column exactly is still used first.
- **Writing to an SFTP path returns the result of the block**, like local and S3 paths, for example from `#writer`. Previously it returned the size of the file written.
- **`#reader`, `#writer`, `#copy_from` and `#copy_to` raise `ArgumentError` for options they cannot use**, instead of ignoring them, so that a misspelled option is reported. This applies to options supplied to the `:stream` mode, which is the default, to `#copy_from` and `#copy_to` without a `mode:`, and to `#copy_from` and `#copy_to` with `convert: false`, including `mode:`. Options for the `:line`, `:array` and `:hash` modes already raised.
- **Misspelled stream options raise when they are set.** An option supplied to `#option` or `#stream` that neither the reader nor the writer for the stream accepts now raises `ArgumentError` when it is set, even when the file name does not include that stream, so a misspelled option is reported wherever the code runs. Previously it was only checked once the stream was used, so for example `IOStreams.path("data.csv").option(:pgp, recipent: "partner@example.org")` was ignored, and only raised for a `.pgp` file, which could be only in production when the path comes from configuration.
- **The gzip and `.enc` streams no longer close the IO supplied to them**, like every other stream. Reading or writing an IO with `IOStreams.stream(io)` through the `:gz`, `:gzip` or `:enc` stream closed `io` when the block finished, while the `:bz2`, `:zip`, `:pgp` and `:encode` streams left it open.
- **Paths compare by their full name, see `#to_s`.** `==` and `<=>` compared only `#path`, so paths with the same key or file name compared equal across S3 buckets, SFTP or HTTP hosts and ports, and stores, for example `IOStreams.path("s3://bucket-a/x.csv") == IOStreams.path("s3://bucket-b/x.csv")`, and comparing a path with anything else raised `NoMethodError`. A path is now equal to a path of the same class with the same `#to_s`, ignoring its streams, and to a `String` equal to its `#to_s`, such as `path == "/home/user/a.txt"`, and is not equal to anything else. Paths with the same location are also the same `Hash` key, and `#uniq` removes duplicates.
- **`#path` is read-only.** `Path#path=` is no longer public, so `path.path = "b.csv"` raises `NoMethodError`. Changing the path in place also changed the path's `#hash`, so a path used as a `Hash` key or in a `Set` could no longer be found, and it was never documented. Use `#join` or `#directory`, which return a new path with the same settings, such as the S3 client or SFTP credentials, or `IOStreams.path` with the new name.
- **`#builder=` is no longer public** on a path or a stream, so it raises `NoMethodError`. It takes an internal object, and was only used by `#join` and `#directory` to clear the streams and options of a new path. To start again without the streams and options set with `#stream` or `#option`, create the path again with `IOStreams.path`.
- **`IOStreams.path`, `IOStreams.stream`, `IOStreams.new`, `IOStreams.join`, `IOStreams.root` and `IOStreams.roots` return a copy instead of an existing path or stream.** `IOStreams.path(path)` and `IOStreams.stream(stream)` returned the path or stream supplied, so `IOStreams.path(path).option(:pgp, passphrase: "secret")` also changed `path`. `IOStreams.join` without any elements, `IOStreams.root` and `IOStreams.roots` returned the root paths themselves, so `IOStreams.join.stream(:none)` changed the root for the whole process. Each now returns a copy with the same streams and options, which is equal to the original, see `#==`, but is a different object. `Path#join` without any elements also returns a copy instead of itself. `#copy_from`, `#copy_to` and `#move_to` still use, and return, the path supplied to them.
- **`IOStreams.add_root` freezes the root path, and returns it frozen.** Previously the path it returned was the root itself, so `IOStreams.add_root(:default, "/data").stream(:gz)` changed the root for the whole process. Changing the returned path now raises `FrozenError`. `IOStreams.root` and `IOStreams.join` still return copies that can be changed.
- **S3 options are strict.** An option supplied to an S3 path, or in the query string of its url, that no S3 request accepts now raises `ArgumentError` when the path is created, for example a misspelled `acll: "public-read"`, as does a request parameter that the path sets itself, such as `key` or `bucket`. Previously an unknown option raised from the AWS SDK when the path was used.
- **An SFTP url without a path is the root directory `/`, and a path starting with `~` is within the login directory.** `IOStreams.path("sftp://host").each_child` lists `/`, like `sftp://host/`. Previously it listed the login directory, but returned children in `/`, so reading a listed file read `/a.csv` instead of the file in the login directory. Use `sftp://host/~` to list the login directory, and `sftp://host/~/data/a.csv` for the file `data/a.csv` within it, as curl does.
- **A failed copy to S3 no longer deletes the target.** `#copy_from` an S3 path no longer checks whether the object exists first, or deletes a new object when the copy fails. S3 only stores an object once its upload completes, so there is never an incomplete object to delete. The delete could instead remove a complete object when only the response to its upload was lost, or an object that another writer created during the copy. This also saves a HEAD request on every copy.
- **A redirect from `https` to `http` is not followed** when reading an HTTP(S) path, and raises `IOStreams::Errors::CommunicationsFailure`. Previously the download continued over plain http, where the data could be read or changed in transit.
- **SFTP `#each_child` is case-insensitive by default**, like local and S3 paths, as documented, so `"*.csv"` also returns `DATA.CSV`. Previously SFTP defaulted to `case_sensitive: true`. Supply `case_sensitive: true` to keep the previous behavior.
- **`#size` raises `IOStreams::Errors::NotFound` for a file that does not exist** on S3, SFTP and HTTP paths, as it already did for a local file, which raises `Errno::ENOENT`, like `File.size` and `Pathname#size`, so that it behaves the same way wherever the file is stored. Previously it returned `nil`. `#size?` still returns `nil` for a file that does not exist, or that is empty, like `File.size?`. A direct copy within S3 of an object that does not exist still raises `Aws::S3::Errors::NoSuchKey`.
- **SFTP `#each_child` returns nothing for a directory that does not exist**, or for a path that is a file, like local and S3 paths. Previously it raised `Net::SFTP::StatusException`. It also only lists the directories that the pattern can match within, so `"*.csv"` lists only the path's directory, where it listed every directory below it, and skips a directory below the path that cannot be read, like `Dir.glob`, where it raised `Net::SFTP::StatusException`. Errors such as a path that cannot be read still raise.
- **S3 `#each_child` returns directories with `directories: true`**, like local and SFTP paths, such as `a` and `a/b` for the key `a/b/c.csv`. Previously it only returned empty folders created with a key ending in `/`, only with a pattern that included `**`, and with the trailing `/`, such as `s3://bucket/a/`. An empty folder is now returned without the trailing `/`, and its attributes are those of the folder object; other directories have empty attributes.
- **An exact name supplied to `#each_child` is returned the same way as one that matches a pattern.** On an S3 path it is now yielded with its attributes, like the children that match a pattern. `IOStreams.each_child` with a name without any pattern characters now yields the attributes for S3 and SFTP paths, and only yields a directory with `directories: true`; previously it yielded only the path, and yielded a local directory regardless.
- **S3 and SFTP `#each_child` match a pattern the same way as local paths.** A pattern is within the path even when it starts with the path's own name, so `IOStreams.path("s3://bucket/data").each_child("data/*.csv")` lists `s3://bucket/data/data/`, where it listed `s3://bucket/data/`. A backslash escapes the next character, as documented, so `each_child("a\\b.csv")` returns `ab.csv`, where S3 and SFTP looked for a name containing the backslash.
- **Local `#each_child` returns `nil`**, like S3 and SFTP paths. Previously it returned an internal array of the names it found, including directories that it did not yield.
- **A local file name of `~`, or starting with `~/`, is within the home directory**, for example `IOStreams.path("~/data/a.csv")` is `/home/user/data/a.csv`, as `sftp://hostname/~/data/a.csv` is within the login directory, so a configured path can change between local files and SFTP without changing the code. Previously it was within a directory called `~` in the current directory. Use `./~/data/a.csv` for that directory, and a warning is logged via `IOStreams.logger` when the current directory contains one. A name such as `~user/a.csv` or `~$Book1.xlsx` is unchanged.
- **`#compressed?` and `#encrypted?` follow the streams.** They are true when a stream in the pipeline compresses or encrypts the data, whether it was inferred from the file name or set with `#stream`, so `IOStreams.path("data.csv.gz.pgp").compressed?` and `IOStreams.path("tempfile2527").stream(:gz).compressed?` are now true, and `IOStreams.path("data.csv.gz").stream(:none).compressed?` is now false. Previously they only checked the last extension of the file name. Compression within PGP or `.enc` data is still not reported, since only the encrypted data records whether it was used.
- **A file name ending in `.encode` no longer applies the `:encode` stream.** It is applied with `#encoding`, see Added, since file names do not name it. Previously `IOStreams.path("notes.encode")` read and wrote its data through the encode stream, which for example raised `Encoding::UndefinedConversionError` for binary data.
- **The `cleaner` option of the `:encode` stream is strict.** A `cleaner` that is neither the name of a built-in rule nor a Proc, such as the String `"printable"`, raises `ArgumentError`. Previously it was ignored, so the data was not cleansed. Use a Symbol, such as `cleaner: :printable`.

- **`#absolute?` no longer ignores leading spaces.** `IOStreams.path(" /a").absolute?` is now false, and `#relative?` true, like `Pathname`, since the name is not `/a`. Previously the name was stripped first.
- **`#each` without a block raises `ArgumentError`**, which says that a block is required. Previously it raised `LocalJumpError` from within the reader.
- **A pattern supplied to `#each_child` or `#children` that is not a String raises `ArgumentError`**, such as `Pathname`'s `children(false)`. Previously it raised `NoMethodError`.
- **The `:stream` mode reads bytes from `.gz` and compressed `.enc` streams**, like every other stream, so `reader { |io| io.read }` returns an `ASCII-8BIT` String whichever streams the file uses. Previously reading the whole of a gzip or compressed `.enc` stream returned it tagged with `Encoding.default_external`, like `Zlib::GzipReader#read`, while a plain, `.bz2` or `.zip` file returned bytes. `#read`, and the `:line`, `:array` and `:hash` modes, still return UTF-8 text.
- **`IOStreams.temp_file` applies the streams that its extension implies**, like any other path, so writing to a temp file with the extension `.csv.gz` compresses the data, and `#compressed?` is true. Previously the path it yielded had `stream(:none)`, so its data was read and written as stored. IOStreams itself no longer uses it for its own temp files. To read or write the data as stored, as before, call `#raw` on the path.

### Deprecated

- **`stream(:none)`.** Use `#raw` to read or write the data as it is stored, see Added, or `#file_name` to read a file that is not named for its format, such as `file_name("data.csv")` for a CSV file named `data.txt`. `stream(:none)` still works as before: it applies no streams, but text is still read and written in its default encoding, such as UTF-8, where `#raw` reads and writes bytes.
- **Setting the encode stream with `option(:encode, ...)` or `stream(:encode, ...)`.** Use `#encoding` instead, see Added. Both still work, and set the same options as `#encoding`, so no change is needed. `stream(:encode, ...)` still stops the streams being taken from the file name, like any other stream set with `#stream`. `option(:encode, ...)` no longer raises `ArgumentError` after `#stream`, or for a stream without a file name.

### Added

- **S3 objects are written without a temp file.** Writing to an S3 path uploads the data as it is written, instead of writing it into a temp file that was uploaded once the block completed, so the file no longer has to fit on the local disk, and the upload overlaps with writing it. Upto 8MB is still stored with a single `put_object` request once the block completes. More is uploaded in parts of 8MB, four at a time in other threads, while the block writes the next part, so writing holds about 40MB in memory. The size of a part doubles after every 1,000 parts, so an object can still be as large as S3 allows, 5TB, within its limit of 10,000 parts. S3 only stores the object once the block completes, as before. When the block raises, including `Interrupt` or the exception that `Timeout` raises, or the upload of a part fails, the upload is aborted, so that S3 discards the parts already uploaded, and the exception is raised unchanged. A failed upload raises the error of the request that failed, such as `Aws::S3::Errors::AccessDenied`, rather than `Aws::S3::MultipartUploadError`. An object larger than 8MB has the ETag of a multipart upload, such as `"...-3"`, rather than the MD5 digest of its data, which it had upto 100MB. With an option that describes the whole object, `content_md5`, `content_length`, `write_offset_bytes`, or the checksum of its data, such as `checksum_crc32`, the data is still written into a temp file first.
- **S3 objects are read without a temp file.** Reading an S3 path requests the object 8MB at a time, as the application reads it, so the application starts on the data straight away, and the object no longer has to fit on the local disk. Previously the whole object was downloaded into a temp file before the block was called. Every range after the first is read from the same version of the object, by its version id in a versioned bucket, and otherwise by its ETag, so an object replaced while it is read raises `Aws::S3::Errors::PreconditionFailed`, rather than returning parts of both. A failure to read part way through the object now raises from within the block, once some of the data has been processed, as it can for any other stream. With the `range` or `part_number` option, which choose the bytes to read, the object is still downloaded into a temp file first. S3 returns no checksum for a range of an object, so the AWS SDK no longer checks one when reading, apart from the transfer's own TLS integrity checks.
- **Writing Excel spreadsheets, `.xlsx` and `.xlsm`**, using the `xlsxtream` gem, for example `IOStreams.path("report.xlsx").writer(:hash) { |io| io << {"name" => "Jack"} }`. The CSV text written becomes the rows of a workbook with one worksheet, streamed with `zip_kit` to the stream below it, such as `.pgp` in `report.xlsx.pgp`, without a temp file of its own. Every cell is text by default, so reading the spreadsheet returns the same CSV. The writer accepts `sheet_name`, which defaults to `"Sheet1"`, `auto_format: true`, which writes values that look like numbers, dates, times or booleans as Excel numbers, dates and booleans, and `use_shared_strings: true`, which stores each distinct value once. Reading ignores `auto_format` and `use_shared_strings`, and raises `ArgumentError` for `sheet_name`, since it always reads the first worksheet.
- **Zstandard compression for `.zst` files**, using the `zstd-ruby` gem, for example `IOStreams.path("data.csv.zst").each(:hash)`. Writing accepts a compression `level`, such as `option(:zst, level: 19)`, and reading returns the contents of every frame in the file, like `zstd -d`. On JRuby, which cannot load the `zstd-ruby` C extension, it uses the [zstd-jni](https://github.com/luben/zstd-jni) jar instead, which the application adds to the classpath, for example with `require_jar "com.github.luben", "zstd-jni", "1.5.7-3"`. On MRI it is built on `Zstd::StreamingCompress` and `Zstd::StreamingDecompress`, since the [zstd-ruby README marks its `Zstd::StreamWriter` and `Zstd::StreamReader` classes as experimental](https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper).
- **`#raw` reads and writes the data as it is stored**, applying no streams and no encoding, for example to checksum a compressed file as it is stored, `Digest::SHA256.hexdigest(IOStreams.path("data.csv.gz").raw.read)`, or to write data that is already compressed, `IOStreams.path("data.csv.gz").raw.write(gzipped)`. Text is read and written as bytes. Setting a stream, option or encoding after it raises `ArgumentError`, since the data is as stored.
- **`#encoding` sets the encoding of the text that the application reads or writes**, and the other options of the `:encode` stream, for example `IOStreams.path("legacy.csv").encoding("Windows-1252:UTF-8")` or `encoding("UTF-8", replace: "?")`. Unlike `option(:encode, ...)`, it can be combined with `#stream`, and works for a stream without a file name; unlike `stream(:encode, ...)`, it keeps the streams taken from the file name, so `IOStreams.path("data.csv.gz").encoding("BINARY")` is still decompressed. Each call merges its options with those already set, and `stream(:none)` removes them.
- **Rescue a missing file, a file that cannot be accessed, or a server that cannot be reached, the same way wherever the file is stored.** Every path tags the exception that its storage raises for a file, directory or S3 bucket that does not exist with `IOStreams::Errors::NotFound`, for access that the storage does not permit, or credentials that are missing or not valid, with `IOStreams::Errors::PermissionDenied`, and for a server that cannot be reached, or cannot handle the request at the time, with `IOStreams::Errors::Unavailable`, which can be retried. A host name that does not resolve, such as a mistyped host, is not `Unavailable`, since retrying will not fix it, unless name resolution failed temporarily, such as during a DNS outage, on Ruby 3.3 or later. So `rescue IOStreams::Errors::NotFound` handles a missing file whether the path is a local file, S3, SFTP or HTTP, and a path held in configuration can change without changing the code. `IOStreams::Errors::AccessDenied`, which IOStreams raises for a path outside the allowed paths, is not a `PermissionDenied`. Previously a missing file raised `Errno::ENOENT` locally, `Aws::S3::Errors::NoSuchKey` on S3, and `IOStreams::Errors::CommunicationsFailure` on SFTP and HTTP, which those also raise for unrelated failures. The tag does not replace the exception, which keeps its class, so code that rescues it by its class still works. Its `#display_name` is the path that failed, without any credentials, and its message starts with it unless it already includes it, so that a log names the file, which for example the message from S3 did not. Only the failure of a path's own request of its storage is tagged, not an exception raised by the block supplied to it, so reading an HTTP path now downloads the file and closes the connection before calling the block. Every kind of failure includes `IOStreams::Errors::StorageError`. See [Errors](https://iostreams.reidmorrison.com/errors).
- **`signer` when reading PGP** requires that the file was signed by that key: reading raises `IOStreams::Pgp::Failure` unless the file has a good signature by a key with that email address, key id or fingerprint, which gpg fully or ultimately trusts. Previously the reader accepted a file that was not signed, or that was signed by any key in the keyring, and `signer:` raised `ArgumentError` when reading. Like the other checks, it is made once the whole file has been read, so supply `verify_first: true` to check it before the contents are processed.
- **`import_and_trust_key` when reading PGP** imports and trusts the sender's public key, and requires that the file was signed by it, or by the `signer` when both are supplied, so that the sender's key does not have to be managed on every server. Since the key itself is supplied, a signature by it is accepted whatever trust gpg places in it. When reading, the trust of the key is only changed when `import_and_trust_level` is supplied, so a key that is already trusted keeps its trust. Previously both raised `ArgumentError` when reading.
- **`#file?`, `#directory?`, `#empty?` and `#size?` for every path**, like the `File` methods with the same names. `#empty?` is true for a file without any data, or a directory without any children. `#size?` returns the size of the file, or nil when it does not exist or is empty. A path is `#blank?` only when its name is empty, so with ActiveSupport loaded, `blank?`, `present?`, `presence` and ActiveModel's `validates_presence_of` and `allow_blank:` behave as before, instead of checking `#empty?`, which can make a request to the file store and raise when it cannot be reached. S3 has no directories, so an S3 path is a directory when any key is within it, or when a folder object exists for it; HTTP has no directories, so every url that exists is a file. SFTP paths also support `#exist?` and `#size`, which raised `NotImplementedError`.
- **`#display_name` for every path** returns its full name without any credentials, for logging, such as `"sftp://example.org/a.csv"` for `sftp://jack:secret@example.org/a.csv?IdentityKey=...`. It removes the user name, password and query of an SFTP url, and the user name, password, query and fragment of an HTTP url, which can hold credentials, such as the signature of a pre-signed url. `#to_s` still includes them, so that the path can be created again from it. `#inspect` already displayed this name.
- **`IOStreams.redact_path_options` and `IOStreams.redact_stream_options`** return the options of a path or its streams with each secret replaced with `"[FILTERED]"`, for an application that stores a url and its options, or its streams, to create the path later, and displays them. For example `IOStreams.redact_path_options("sftp://example.org/a.csv", password: "secret")` returns `{password: "[FILTERED]"}`. Each path class declares its secrets with `sensitive_option_names`: the SFTP `password` and `IdentityKey` ssh option, the S3 `secret_access_key` and customer encryption keys, and the HTTP `password`, `parameters` and cookie headers. Every value is replaced when the url is not valid, or when its scheme is registered with a class that does not declare its secrets. As a precaution any option whose name contains `passphrase`, `password`, `secret`, `token`, `credential`, `auth`, `apikey` or `privatekey` is also replaced, such as the headers `Authorization` and `X-Api-Key`, and names match in any case, with or without `_` and `-`. The options within a Hash option, such as `ssh_options:`, `client:` or `headers:`, are replaced the same way, as are those within an Array of Hashes or of `[name, value]` pairs. `#inspect` on a path or stream hides options with these names too.
- **`#allowed?` for every path** returns whether it can be accessed, which is whether it is within the allowed paths, like `IOStreams.allowed_path?`, for example `IOStreams.path("/etc/passwd").allowed?`.
- **Write to HTTP(S) paths.** Writing to an `http://` or `https://` path uploads the file with an HTTP PUT, for example `IOStreams.path("https://example.com/upload/report.csv").write(data)`. The file is written to a tempfile first and uploaded once the block completes, with its `Content-Length`. Only a `307` or `308` redirect to the same scheme, host and port is followed when writing, so that a redirect cannot send the data being uploaded to another server. Previously writing to an HTTP path raised `NoMethodError`.
- **`headers:` for HTTP(S) paths** adds headers to every request, when reading and when writing, for example a bearer token or the `Content-Type` of an upload. Since any header may hold a credential, the headers are not resent across a redirect to another scheme, host or port.
- **`#exist?`, `#size` and `#delete` for HTTP(S) paths.** `#exist?` and `#size` use an HTTP HEAD, and `#delete` uses an HTTP DELETE. A `404 Not Found` or `410 Gone` response means the file does not exist. `#delete` follows the same redirects as writing. `#move_to` from an HTTP path now deletes it once it is copied; previously it copied the file and then raised `NotImplementedError`. `#mkpath` does nothing, like S3, so `#move_to` an HTTP path also works.
- **`#delete` for SFTP paths** deletes a file, or an empty directory, and does nothing when it does not exist, like local and S3 paths. It uses `net-sftp`, like `#each_child`. `#move_to` from an SFTP path now deletes it once it is copied; previously it copied the file and then raised `NotImplementedError`, leaving both copies.
- **Each HTTP(S) redirect that is followed is logged** at info level via `IOStreams.logger`, without any user name, password or query string, which can hold the signature of a pre-signed url.
- **`#compressed?` and `#encrypted?` for streams**, such as `IOStreams.stream(io).stream(:gz).compressed?`, like paths.
- **Register a format with `IOStreams.register_extension(:xz, MyXz)`**, a module that answers `reader_class`, `writer_class`, `compressed?` and `encrypted?`, and extends `IOStreams::StreamFormat`, which checks the options of its reader and writer and opens them, so that a custom format can declare that its data is compressed or encrypted. The built-in formats are registered this way, so their readers and writers are now loaded when first used, rather than when `iostreams` is required. Registering the reader and writer classes still works, for a format that is neither compressed nor encrypted.

- **Invalid UTF-8 names where it is.** Data that is not valid in the encoding that it is read or written in raises `IOStreams::Errors::InvalidEncoding`, an `Encoding::UndefinedConversionError`, so code that rescues that still works. Its message gives the byte offset of the first invalid byte, within the data after any decompression or decryption, and, when reading a line at a time, such as with `each(:line)` or `each(:hash)`, the line that it is on, for example `"\xE9" is not valid UTF-8 at byte offset 1043 on line 12`; `#byte_offset` and `#line_number` return them. The lines before the invalid data are read first, where previously the error was raised for the whole block of up to 64KB that held it, before any of its lines were read. Previously the message only gave the invalid bytes.
- **Convert text from one encoding to another while reading**, with Ruby's `"external:internal"` form of the `:encode` stream's `encoding`, like `File.read(name, encoding: "Windows-1252:UTF-8")`. For example `IOStreams.path("legacy.csv").encoding("Windows-1252:UTF-8").each(:hash)` returns UTF-8 strings, where previously it could only return Windows-1252 strings. Writing with the same option writes the external encoding.
- **`#delete_all` for S3 and SFTP paths**, like local paths. On S3 it deletes the object, and every key within the path as a directory, in batches of up to 1,000 keys; a key that only starts with the same characters, such as `a.csv` for `s3://bucket/a`, is not deleted. On SFTP it deletes the directory and everything within it, without following symbolic links. Previously both raised `NotImplementedError`.
- **`#respond_to?` is false for an operation that a path does not support**, such as `#each_child` and `#delete_all` on an HTTP path, like Ruby's own methods that are not implemented on the platform, such as `Process.fork` on Windows. Calling it still raises `NotImplementedError`, whose message now names the path class, the operation and the path.
- **`#mtime` for every path**, like `File.mtime`: the time a local file was modified, the `last_modified` time of an S3 object, the `mtime` of an SFTP file, or the `Last-Modified` header of an HTTP(S) url, which is nil when the server does not supply it. It raises `IOStreams::Errors::NotFound` when the file does not exist.
- **`#relative_path_from`**, like `Pathname#relative_path_from`, returns the name of a path relative to another path in the same store as a String, for example to copy every file within a directory to another store. It raises `ArgumentError` for a path in another store, such as another S3 bucket or SFTP host.
- **Each temp file that IOStreams uses is logged** at debug level via `IOStreams.logger`, when it is created, with what it holds, such as `Created temp file /tmp/iostreams_s320261008-41-1x5yq2 for the download of s3://bucket/data.csv`, and when it is deleted, with its size, so that it can be seen when, and why, a file was copied to local disk. See [When temp files are used](https://iostreams.reidmorrison.com/config#when-temp-files-are-used).
- **`#/`, `#cleanpath` and `#sub_ext`**, like `Pathname`. `#/` joins like `#join`, so an absolute element is joined to the path rather than replacing it. `#cleanpath` removes `.`, `..` and repeated `/` without accessing the file, and keeps the streams and options. `#sub_ext` replaces the last extension, and clears the streams and options, since they were for the old file name.

### Changed

- **Reading CSV is faster.** `CSV.parse_line` creates a parser for each line, which costs several times more than parsing the line, so each line is now parsed directly. Converting a row into a record also no longer checks every column of every row for a blank or rejected column name, which made it slower than parsing the line, so reading PSV records is faster too. Reading rows, such as with `each(:array)`, is 4 to 6 times faster, and reading records, such as with `each(:hash)`, 3.5 to 5 times faster, on MRI, YJIT and JRuby. A line with a line break, or with invalid quoting, is still parsed by `CSV.parse_line`, so the values, their encodings, and the errors raised are the same as before.
- **Writing CSV is faster.** `CSV.generate_line` also creates a CSV object for each line, so each line is now written directly. Writing rows, such as with `writer(:array)`, is 2.5 to 4.5 times faster, and writing records, such as with `writer(:hash)`, 1.4 to 2.3 times faster, on MRI, YJIT and JRuby. A row with a value whose text is neither valid UTF-8 nor ASCII is still written by `CSV.generate_line`, so the lines written, and the errors raised, are the same as before.

### Fixed

- An S3 or SFTP url can contain the characters that names often do, but a url cannot, such as `s3://bucket/données/café.csv` or `sftp://host/data/report [1].csv`. Previously creating the path raised `URI::InvalidURIError` for a character that is not ASCII, or for `[`, `]`, `{`, `}`, `|`, `\`, `^`, `` ` ``, `<`, `>` or `"`, as did creating it again from its `#to_s`, for example a path found by `#each_child` that an application stored to read later. The key of an S3 url, and the path of an SFTP url, is the name as it is, so only a `%`, `?` or `#` in it must be percent-encoded, which `#to_s` now does, see above. An HTTP(S) url must still be percent-encoded, as any url is. The user name and password of an SFTP url are taken as they are, including characters that are not ASCII, or `@`, since the password ends at the last `@`, where previously they raised `URI::InvalidURIError`. A host with a space, or a character that is not ASCII, raises `ArgumentError`, without the password in its message.
- SFTP `#each_child` on a host that is an IPv6 address, such as `sftp://[::1]:2222/data`, returns its children. Previously it raised `URI::InvalidURIError`, since the url of each child was built without `[` and `]`. The url of each child now has the host and port as they are in the url, such as `sftp://host:22/data/a.csv`, as `#join` does, where the port 22 was dropped.
- A file whose name is not valid UTF-8, such as one that a Windows program wrote in Latin-1 to a Linux file system, can be listed, matched and used by its name. Previously `#each_child` raised `ArgumentError: invalid byte sequence in UTF-8` when such a file was in the directory, with the default `case_sensitive: false`, even when the pattern did not match it, as did creating the path, including from a `file://` or SFTP url, reading or writing it, and `#cleanpath` and `#relative_path_from`. Every S3 key is UTF-8, so creating an S3 path with such a name raises `ArgumentError`, naming it, rather than an error from the AWS SDK when it is first used. The name is used as it is, so the file can still be opened, moved and deleted. `#display_name` and `#inspect` show each byte of the name that is not valid UTF-8 as `\xHH`, such as `/data/caf\xE9.csv`, so that it can be logged, and show a name held as binary as UTF-8.
- SFTP `#each_child` returns names as UTF-8. Net::SFTP returns each name as bytes, so the name of a file such as `café.csv` was binary, and did not equal the same name as UTF-8, for example read back from a database, and `#delete_all` raised `Encoding::CompatibilityError` for it within a directory whose name is not ASCII. A name that is not valid UTF-8, such as one in Latin-1, keeps its bytes, see above.
- Reading and writing an SFTP file whose name is not ASCII names the same file. The sftp program received each name escaped by `String#inspect`, so it looked for `caf\xC3\xA9.csv` instead of `café.csv` when the name was binary, as the names returned by `#each_child` were, or not valid UTF-8. A name with a control character, such as a line feed, now raises `ArgumentError` before sftp is started, since its commands are lines.
- An S3 path loads the `aws-sdk-s3` gem when it is first needed, so that a process without the gem can create, join, compare and display an S3 path, such as with `#display_name`. Previously creating one raised `LoadError`. Supplying S3 options loads it to check them when it is installed. Without it, every request raises `LoadError`, and writing raises it before the block writes any data, instead of once the data has all been written to a temp file.
- SFTP `#exist?`, `#file?`, `#directory?`, `#empty?`, `#each_child` and `#delete` treat SFTP status 10, "no such path", which some servers send from version 4 of the SFTP protocol, as a file that does not exist, like status 2. Previously they raised `Net::SFTP::StatusException`.
- `#inspect` shows the full name of a path, such as `#<IOStreams::Paths::S3:s3://bucket/a.csv pipeline={}>`, without any user name, password or query of an SFTP or HTTP url. Previously it showed only `#path`, such as `a.csv`, so paths in different buckets or on different hosts looked the same. The warning logged when `#each_child` skips a child outside the allowed paths also no longer includes the password of an SFTP or HTTP url.
- `#directory` of an S3 key without a directory, such as `s3://bucket/a.csv`, is the bucket `s3://bucket/`. Previously it was the key `.`, shown as `s3://bucket/.`, so a path joined to it, such as `path.directory.join("b.csv")`, used the key `./b.csv`, a different object from `b.csv`.
- `#directory` of an HTTP(S) url without a directory, such as `https://example.com` or `https://example.com/a.csv`, is the host `https://example.com/`. Previously a url without a path raised `URI::InvalidComponentError`. An unchanged directory or file name keeps its encoding in the url, so the directory of `https://example.com/a%2541/b.csv` is `https://example.com/a%2541`, and a `%` in a name supplied to `#join` that does not start a percent-encoded character, such as `100%.csv`, is encoded as `%25`, where it was left in the url as is.
- `#absolute?` is true for S3, SFTP and HTTP(S) paths, which are never relative. Previously it was false for every S3 path, for an SFTP path within the login directory, such as `sftp://host/~/a.csv`, and for an HTTP url without a path, so both `#absolute?` and `#relative?` were false.
- A frozen path, such as a root path held in a constant, can be inspected, and an S3 path can list its children and check that it exists. Previously each raised `FrozenError`, whose message was itself replaced by `...` since inspecting the path failed too. Paths joined to it, as in `EXPORT.join("a.csv").read`, already worked.
- `#freeze` on a path that already has streams or options set, for example `IOStreams.add_root(:exports, IOStreams.path("a.csv.gz").option(:gz, level: 1))`, now stops `#option`, `#stream`, `#option_or_stream`, `#remove_from_pipeline` and `#file_name=` from changing it. Previously `#freeze` only froze the path itself, not the builder holding its streams, options and file name, so a path built before it was frozen could still be changed, for the whole process when it was a root path. `#pipeline` and reading still work on a frozen path, as they already did.
- A frozen HTTP path, such as a root path, can be read, and `#exist?`, `#size`, `#delete` and `#allowed?` work on it. Previously each raised `FrozenError`, since the path's url memoized into an instance variable the first time it was needed, the same issue `#each_child` and `#exist?` had on S3, fixed above; `#allowed?` raised instead of returning `false`.
- An S3 path shares its client with the paths copied from it, such as by `#join` or `#directory`, so the client and its credentials are created once. Previously each copy created its own client unless the original had already created one.
- Chaining `<<` when writing arrays or hashes, for example `io << row1 << row2` within `writer(:array)` or `writer(:hash)`, writes each row. Previously `<<` returned the underlying line writer, so every row after the first in a chain was written as its Ruby `inspect` output, such as `{"name" => "Jill"}`.
- `IOStreams.each_child` with a pattern that has no directory, such as `IOStreams.each_child("*.csv")`, searches the current directory. Previously it searched the root directory `/`, so `"**/*.csv"` searched the entire file system.
- `IOStreams.temp_file` runs the block once. Previously, when the block raised `Errno::EEXIST`, for example from `Dir.mkdir`, the block was run again with a new file name up to 5 times, and then a `RuntimeError` was raised instead. It also no longer chooses the name of a file that already exists, which it then deleted when the block finished.
- S3 `#each_child` only returns children within the path. Previously it listed every key starting with the same characters, so `IOStreams.path("s3://bucket/reports").each_child("*.csv")` also returned `s3://bucket/reports_x.csv`, and `"**/*.csv"` returned files in `reports_2024/`. It also no longer parses the path as a URL, so a path containing `+` or `%`, for example one built with `#join`, lists its children instead of none or raising `URI::InvalidURIError`, and the children keep the options of the path, such as `request_payer`.
- `#join` and `#directory` on HTTP and SFTP paths change the url. Previously only `#path` changed, so `IOStreams.path("https://example.com/files").join("report.csv").read` downloaded `https://example.com/files`, allowed paths were checked against that url, and `#to_s` of a joined SFTP path returned the original url. Characters in an HTTP path that cannot appear in a url, such as a space, `?` or `#`, are percent-encoded in the url.
- A failed `#copy_from` or `#copy_to` no longer deletes an existing target. Previously the target was opened, emptying a local file, before the source was opened, so copying from a missing source deleted the target, and when any copy to S3 failed the existing object, which is only replaced once the upload completes, was deleted. The source is now opened first, and a copy no longer checks whether the target exists, or deletes it when the copy fails. Each path cleans up after a failed write itself, the same way for a copy as for `#writer`: a local file is removed, and S3, SFTP and HTTP only store the file once it is complete. A path class registered with `IOStreams.register_scheme` that writes directly to its store should likewise remove an incomplete file when writing fails.
- Reading a PGP file no longer hangs when the block returns before reading the whole file, for example `reader(:line, &:readline)` or `reader { |io| io.read(10) }` on a file larger than the pipe buffer. The rest of the file is now decrypted and checked by gpg before the result is returned.
- The `:printable` and `:replace_non_printable` cleaners of the `:encode` stream no longer change the string supplied to the writer when writing binary data, for example with `encoding: "ASCII-8BIT"`, which also raised `FrozenError` for a frozen string.
- Reading a CSV file with an unbalanced quote no longer takes quadratic time when the data is read as UTF-8 through an encode stream. The size of such a line is now limited in bytes rather than characters.
- Reading a Zip file without the `rubyzip` gem raises a `LoadError` asking to install `rubyzip`. Previously it asked for `rubyzip v1.x`, which is not a gem name, and suggested that later versions, such as `rubyzip` 3, are not supported.
- Reading lines of UTF-8 text with multi-byte characters, for example through an encode stream with `encoding: "UTF-8"`, is now about as fast as reading the same data as binary. Previously each line rescanned the rest of the 64KB block that it was read from, which made reading lines many times slower. The limit on a line without a delimiter, which raises `IOStreams::Errors::DelimiterNotFound`, now counts bytes, as its message says, rather than characters.
- Copying between S3 paths with `convert: false`, or with `#move_to`, copies a key that contains a space, `+`, `%`, `?` or another character that must be url-encoded. Previously the key was not url-encoded, which S3 requires, so the copy failed or copied another object.
- The format of a file is detected from an upper case extension, so `DATA.JSON` is read as JSON. Previously it was read as CSV, the default. The format and the streams are also no longer detected from the name of the file before its first `.`, or from a directory name: previously `hash.txt` was read as the `:hash` format, a file named `gz` was read as gzip, and `reports.json/data.txt` was read as JSON.
- Local `#each_child` returns the children of a directory whose name contains a pattern character such as `[`, `{`, `*` or `?`. Previously it returned nothing, or the children of other directories. Within the pattern itself such characters must still be escaped with `\`. It also no longer yields the directory itself, as `dir/.`, with `hidden: true` and `directories: true`.
- `#copy_from` and `#copy_to` with `convert: false` no longer change the streams of the source or target path. Previously both paths were left with no streams, as with `stream(:none)`, so for example a later `#read` of a `.gz` source returned its compressed data, and a source with an `#option` raised `ArgumentError`.
- `IOStreams::Pgp.list_keys` returns `[]` for an empty keyring, instead of raising `IOStreams::Pgp::Failure`, and `IOStreams::Pgp.pgp_version` raises `IOStreams::Pgp::Failure` with gpg's error when `gpg --version` fails, instead of `NameError`.
- `IOStreams::Pgp.import` returns the name of a key whose user id has no email address, with a `nil` email. Previously it returned the name `"Joe Bloggs"` and the email address `"pgp_test@iostreams.net"`, values left over from its tests, for such a key, and for a key whose user id it could not read.
- `IOStreams::Pgp.import` returns `private: true` for a key whose secret key it imported, on GnuPG 2.4 and later. Previously it returned `private: false` for that key, and `private: true` for the key imported after it, since from 2.4 gpg reports a secret key after its public key, rather than before.
- `IOStreams::Pgp.key_info` shows a private key, and `IOStreams::Pgp.import_and_trust` imports and trusts one, as documented, on GnuPG 2.2.8 and later. Previously both raised `IOStreams::Pgp::Failure`, since from 2.1 gpg cannot show a secret key without a command, so a private key could only be imported with `IOStreams::Pgp.import`, without being trusted.
- Reading a zip file whose first entry is a folder reads the first file in it. Previously it raised `NoMethodError`.
- `#move_to` from S3 to a path that is not on S3, such as a local file, returns the target path. Previously it returned the number of bytes copied.
- `#mkpath` and `#mkdir` on SFTP paths create the directories when a file is written, so `#move_to` an SFTP path, which calls `#mkpath`, works. Previously `#mkpath` raised `NotImplementedError`, which also made every `#move_to` an SFTP path raise, and `#mkdir` did nothing.
- Reading or writing an SFTP path without a username connects as the user from the ssh config, or the current user, as `sftp` does. Previously it failed with the usage text of `sftp`.
- The `ArgumentError` messages for calling both `#option` and `#stream`, or `#option` without a file name, no longer end with a stray `}`.
- `file://` urls refer to local files, for example `IOStreams.path("file:///home/user/a%20b.csv")` is `/home/user/a b.csv`. Previously the whole url was used as a relative file name, so reading raised `Errno::ENOENT`. A file url is absolute, so one with a host other than `localhost`, such as `file://a.txt`, or with an unencoded `?` or `#`, raises `ArgumentError`. A file url can also start with `~` for the home directory, as an SFTP url can for the login directory, for example `file://~/data/a.csv` or `file:///~/data/a.csv`, so a configured url can change between local files and SFTP without changing the code.
- `IOStreams.home` and `IOStreams.working_path` are now documented.
- Writing PGP with `import_and_trust_key` and an `import_and_trust_level` below `5` (Ultimate), such as the documented `import_and_trust_level: 4`, encrypts the file. Previously gpg raised `There is no assurance this key belongs to the named user`, since gpg only treats a key as valid on its own when it is ultimately trusted. The imported key is now supplied to gpg in a file with `--recipient-file`, which gpg treats as valid without changing its trust, on gpg v2.1.14 and later.
- A path with an option for a stream that only applies when writing, such as `option(:enc, compress: false)` or `option(:gz, level: 9)`, can be read, and one with an option that only applies when reading, such as the PGP `passphrase`, can be written, so the same path can be written and then read. Each direction ignores the options of the other that it does not need, such as `compress` when reading `.enc`, whose header records whether the file was compressed. Previously the option raised `ArgumentError` in the other direction.
- An S3 path with an option that only some requests accept, such as `acl:` or the documented `?acl=` url form, can be read, and each S3 request is supplied the options it accepts. Previously every option was supplied to reading and writing, so reading a path with `acl:` raised `ArgumentError: unexpected value at params[:acl]`, while `#exist?`, `#size`, `#delete` and `#each_child` were supplied none, so for example they did not apply `request_payer` or the `sse_customer_*` options.
- HTTP `parameters:` are added to a url that already has a query string, replacing any parameter with the same name, so that the last value supplied is used, and are added before a `#fragment`. Previously they were appended after a second `?`, so `https://example.org/file?a=1` with `parameters: {b: 2}` requested `?a=1?b=2`. Empty `parameters:` leave the url unchanged, instead of adding a `?`.
- Reading rows or records keeps a newline within a quoted CSV value in its row when CSV is the default format: for a file name without a tabular extension, such as `data.txt`, a stream without a file name, or a spreadsheet, whose cells are read as CSV. Previously the lines were split at the newline, so `each(:array)` and `each(:hash)` raised `CSV::MalformedCSVError`, for example for an Excel cell containing a line break. Lines are also split for a format supplied when reading, such as `each(:hash, format: :json)`, rather than the one detected from the file name.
- `#inspect` on a stream, such as `IOStreams.stream(io)`, no longer displays a passphrase set with `#option` or `#stream`, as `#inspect` on a path already did. A custom reader or writer declares the options that hold a secret, such as an API key, with `sensitive_option_names`, so that their values are not displayed either. Previously only an option whose name contained `passphrase`, `password` or `secret` was hidden, and only by `#inspect` on a path.
- The version of `gpg` is compared by its numbers, so that GnuPG 2.10 or later will be supplied `--no-symkey-cache`, which stops it from caching the session keys of the data that it decrypts. Previously the version was compared as a decimal number, which would treat 2.10 as 2.1.
- The `:encode` stream set with `#stream` converts the text that the application reads or writes, whatever order the streams are set in, as it already did when set with `#option`. Previously `stream(:gz).stream(:encode, encoding: "UTF-8")` decoded the compressed data, which raised `Encoding::UndefinedConversionError`, while `stream(:encode, encoding: "UTF-8").stream(:gz)` worked.
- Reading or writing `.enc` loads the `symmetric-encryption` gem when the application has not required it. Previously it raised `NameError: uninitialized constant SymmetricEncryption`, since the check for whether the gem was loaded found `IOStreams::SymmetricEncryption` instead.
- A local `#realpath` keeps the streams, options and `create_path:` of the path, since it is the same file. Previously it returned a new path without them, so for example `IOStreams.path("a.csv", create_path: false).realpath.write("x")` created the directories.
- The docs said that `IOStreams.path("sample/data").mkpath` creates `sample/data`. `#mkpath` treats the last element as the file name, so it creates `sample`; `#mkdir` creates the whole path.
- Reading a local `.zip`, `.xlsx` or PGP file, and writing a local PGP file, no longer copies the file into a temp file: the zip reader and the `creek` gem read the file itself, and `gpg` reads a PGP file through its file descriptor, and writes one through its stdout. Reading or writing one on S3, SFTP or HTTP now uses only the temp file that the path downloads into or uploads from, where previously the format also copied it into a second temp file of the same size. The same applies to a `File` supplied to `IOStreams.stream`: a zip file or spreadsheet read from its start, while its name still opens the same file, and a PGP file, including the file of a `Tempfile`, read from where it is. A `File` that was not opened for reading, or for writing, still raises `IOError`, rather than being opened again by its name. The docs now list [when temp files are used](https://iostreams.reidmorrison.com/config#when-temp-files-are-used), and no longer say that GnuPG cannot stream.
- PGP data within another stream, such as `data.csv.pgp.gz`, or in an IO that is not a `File`, such as a `StringIO` or a socket, is decrypted or encrypted through the stdin and stdout of `gpg` as it is read or written, instead of being copied into a temp file first. The data moves between `gpg` and the IO in the application's thread, so an IO that only that thread can use, such as one that reads an `Enumerator`, still works, and `Timeout` interrupts a read or write of an IO that stalls. An error about the stream names it as the stream rather than a temp file, such as `PGP stream was not signed by sender@example.org`.
- Reading PGP data that ends within its first packet, such as a file that is still being uploaded, raises `IOStreams::Pgp::Failure`. Previously `gpg` exited successfully without any output, so the data was read as an empty file.
- Writing to a local path removes the partial file for any exception, such as `Interrupt`, or the one that `Timeout` raises within its block from timeout v0.4, the default from Ruby 3.3. Previously only a `StandardError` removed it.
- Writing a file larger than 5MB to S3 uploads it with `Aws::S3::TransferManager#upload_file`, which `aws-sdk-s3` v1.197.0 added in place of `Aws::S3::Object#upload_file`. Previously it called `Aws::S3::Object#upload_file`, so the SDK printed a deprecation warning, and the upload would fail once the SDK's next major version removes that method. With a version of `aws-sdk-s3` before v1.197.0, `Aws::S3::Object#upload_file` is still used.

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
