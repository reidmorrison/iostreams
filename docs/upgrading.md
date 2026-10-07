---
layout: default
title: Upgrading
heading: Upgrading IOStreams
description: >-
  What changes when upgrading IOStreams to v3.0, v2.1 or v2.0, and the security
  settings to review in your application when upgrading.
---

This page covers the changes that may need updates to your application when upgrading IOStreams,
and the security issues to check. For every change in each release, see the
[CHANGELOG](https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md).

## Upgrading to v3.0

v3.0 is a major release. It reads text as UTF-8 by default, described first, and makes the breaking
changes that were postponed from v2.1. In v2.1 each of those logged a warning via `IOStreams.logger`
when it would change the result, so check your logs from v2.1 for them before upgrading. It also
includes bug fixes that change behavior that existing code may depend on, described at the end of
this section.

### Text is read as UTF-8

Lines, rows and records, read with `each`, or with `reader` in the `:line`, `:array` or `:hash` mode,
are now UTF-8 strings, and the data must be valid UTF-8. `read` without a length returns the whole
file as UTF-8 without checking it, like `File.read`, so that it can still read a binary file, such as
an image. Previously lines, rows and records were binary (`ASCII-8BIT`) strings, apart from values
parsed from JSON, and `read` returned binary data for most files, but data in
`Encoding.default_external` for `.gz` and `.enc` files, which depends on the locale. A binary string
cannot be combined with UTF-8 text, so for example writing a CSV row that mixed a value read from a
file with a non-ASCII UTF-8 value raised `Encoding::CompatibilityError`.

Reading lines, rows or records of a file that is not valid UTF-8, such as a Windows-1252 export, now
raises `Encoding::UndefinedConversionError`. Fixed width columns now count characters, as they
already did when writing, so a file whose sizes count bytes raises
`IOStreams::Errors::InvalidLineLength` for a line with a multi-byte character.

The `:stream` mode, `read` with a length, such as `read(1024)`, and writing are unchanged: they read
and write bytes.

Fix: read a file in another encoding by setting it on the encode stream, for example
`option(:encode, encoding: "Windows-1252")`, whose strings are then in that encoding, or supply
`replace:` to replace invalid characters instead of raising. To read binary strings, as before, supply
`option(:encode, encoding: "BINARY")`, or `stream(:encode, encoding: "BINARY")` for a stream without
a file name. See [Text and binary data](streams#text-and-binary-data).

### Column restrictions apply to every input

When reading records, `allowed_columns`, `required_columns` and `skip_unknown` now apply to every
input. Previously they were ignored for JSON and `:hash` input, when `columns:` was supplied, and
with `cleanse_header: false`. When reading rows with `each(:array)`, they now also apply to the
supplied `columns:`, and to the header row with `cleanse_header: false`.

When either `allowed_columns` or `required_columns` is set, JSON keys are now cleansed the same way
as a header row, for example `"Name"` becomes `"name"`. Unknown keys are skipped, or raise
`IOStreams::Errors::InvalidHeader` when `skip_unknown: false`, and a record that is missing a
required column raises `IOStreams::Errors::InvalidHeader`.

Fix: check that the JSON files you read with these options have the expected keys. See
[Header options](formats#header-options). To keep the previous behavior, set
`IOStreams.enforce_column_restrictions = false` in an initializer, which defaulted to false in v2.1.
Renaming an uploaded file from `.csv` to `.json` then bypasses the restrictions.

### BZip2 options are strict

The BZip2 reader and writer now raise `ArgumentError` for an option that neither of them accepts, like
every other stream. Previously they ignored it. They accept `autoclose`, `first_only` and `small` when
reading, and `autoclose`, `block_size` and `work_factor` when writing, and each ignores the options of
the other.

Fix: correct or remove the option. See
[Options for reading and writing](streams#options-for-reading-and-writing).

### Zip `zip_file_name` is removed

The Zip writer no longer accepts `zip_file_name`, which the documentation replaced with `entry_file_name`
long ago, and `option(:zip, zip_file_name: "a.csv")` raises `ArgumentError`.

Fix: use `entry_file_name`, which names the file within the zip file when writing, and chooses the file
to read: `option(:zip, entry_file_name: "a.csv")`.

### PGP `export` without an email or key id

`IOStreams::Pgp.export(email: nil)` without a `key_id:` now raises `ArgumentError`, instead of
`IOStreams::Pgp::Failure`.

### PGP email addresses match exactly

An email address supplied as a PGP `recipient` or `signer`, or as the `email:` of
`IOStreams::Pgp.list_keys`, `key?`, `export`, `delete_keys` or `set_trust`, now only matches keys with
exactly that email address, ignoring case. gpg treats a bare email address as a search for any user id
that contains it, so previously `bob@example.com` also matched `jimbob@example.com`.

Fix: supply the exact email address of each key. To search the way gpg does, supply a value that is not
just an email address, such as `*example.com`.

### Reading gzip returns every member

Reading a gzip file that contains several members, for example concatenated gzip files, now returns
the contents of every member, instead of only the first. The stream supplied to the block when reading
gzip is no longer a `Zlib::GzipReader`; like the other streams it responds to `#read`, `#readpartial`
and `#eof?`.

Fix: replace calls such as `#gets` on the gzip stream with `each(:line)`.

### The encode stream validates every read

With the `:encode` stream, data read from a file is treated as already being in the requested encoding,
so valid characters are kept instead of being replaced, and an invalid character raises
`Encoding::UndefinedConversionError` unless `replace:` is supplied. Previously reading lines let invalid
characters through without raising.

Fix: supply `replace:`, for example `option(:encode, encoding: "UTF-8", replace: "")`, to replace
invalid characters instead of raising.

Data read through the encode stream is treated as bytes in the requested encoding whichever streams it
was read through. Previously reading the whole of a `.gz` or `.enc` file converted it from
`Encoding.default_external` into the requested encoding, unlike the same data in a plain file, so for
example `option(:encode, encoding: "Windows-1252").read` raised for a Windows-1252 `.gz` file.

Fix: to convert a UTF-8 file into another encoding, read it as UTF-8 and call `String#encode`.

### Fixed width columns count characters through the encode stream with `replace:`

Reading a fixed width file through the `:encode` stream with `replace:`, for example with
`option(:encode, encoding: "UTF-8", replace: " ")`, now counts the `size` of each column in
characters, since the encode stream keeps valid characters. Previously each byte of a non-ASCII
character was replaced, so the sizes counted bytes, while `Zürich` was read as `Z  rich`. A file whose
sizes count bytes now raises `IOStreams::Errors::InvalidLineLength` for a line with a multi-byte
character. Without `replace:`, the sizes already counted characters.

Fix: read a file whose sizes count bytes as binary, with `option(:encode, encoding: "BINARY")`, or in
its single-byte encoding, such as `option(:encode, encoding: "ISO-8859-1")`. See
[Fixed width files](formats#fixed-width-files).

### A `+` in an S3 or SFTP url is kept

A `+` in the path of an S3 or SFTP url is now kept, so `IOStreams.path("s3://bucket/a+b.csv")` reads
the key `a+b.csv`. Previously it was decoded as a space, and read the key `a b.csv`.

Fix: use a space, or `%20`, in the url for a space.

### The path of an HTTP url is decoded

`#path` of an `http://` or `https://` path is now decoded, like S3 and SFTP paths, so
`IOStreams.path("https://example.com/my%20file.csv").path` is `/my file.csv`, and `#basename` is
`my file.csv`. Previously it was `/my%20file.csv`. `#to_s` still returns the url unchanged. A url without
a path, such as `https://example.com`, now has the path `/`, where it was empty.

Fix: use `#to_s` where the url is needed, and remove any code that decodes the `#path` of an HTTP path.

### A direct copy between S3 paths returns the number of bytes

`#copy_from` and `#copy_to` with `convert: false` between two S3 paths now return the number of bytes
copied, like every other copy. Previously `#copy_from` returned the response from the S3 `copy_object`
call, and `#copy_to` returned the target path. `#move_to` still returns the target path.

Fix: use the target path that was supplied to `#copy_to`, instead of its return value.

### Local `each_child` honors `case_sensitive:`

`#each_child` and `IOStreams.each_child` on local files now honor `case_sensitive:` on every platform.
Previously, on a case-sensitive file system such as on Linux, the default `case_sensitive: false` was
ignored unless nothing matched, and on a case-insensitive file system such as on macOS,
`case_sensitive: true` was ignored.

Fix: on Linux, check that patterns that relied on matching case, such as `"*.csv"` in a directory that
also has `DATA.CSV`, return the files you expect, or supply `case_sensitive: true`.

### The file within a written zip file is named after the path

Writing to a path such as `example.csv.zip` now names the file within the zip file `example.csv`, as
documented, instead of `file`.

Fix: if the program that reads the zip file expects the name `file`, supply
`option(:zip, entry_file_name: "file")`.

### Hash keys match columns once cleansed

When writing a hash with `columns:`, or reading JSON or `:hash` records with `columns:`, a key such as
`"First Name"` now supplies the value of the column `first_name`, since they are the same once cleansed
like a header row. Previously the column was empty.

Fix: if a column must stay empty, remove the matching key from the hash before writing it.

### Writing to SFTP returns the result of the block

Writing to an SFTP path, for example with `#writer`, now returns the result of the block, like local
and S3 paths, instead of the size of the file written.

Fix: if you need the size, return it from the block, for example the total of what `io.write` returns.

### Options that a mode or copy cannot use raise `ArgumentError`

`#reader` and `#writer` in the `:stream` mode, which is the default, `#copy_from` and `#copy_to` without
a `mode:`, and `#copy_from` and `#copy_to` with `convert: false`, now raise `ArgumentError` for any
option, instead of ignoring it. Options for the `:line`, `:array` and `:hash` modes already raised.

Fix: remove the option, which had no effect. To configure a stream, use `#option` or `#stream`, for
example `path.option(:pgp, passphrase: "secret").reader { |io| io.read }`.

### Misspelled stream options raise when they are set

An option supplied to `#option` or `#stream` that neither the reader nor the writer for the stream
accepts now raises `ArgumentError` when it is set, even when the file name does not include that stream.
Previously it was only checked once the stream was used, so for example
`IOStreams.path("data.csv").option(:pgp, recipent: "partner@example.org")` was ignored, and only raised
for a `.pgp` file, which could be only in production when the path comes from configuration.

Fix: correct or remove the option. See
[Options for reading and writing](streams#options-for-reading-and-writing).

### Gzip and `.enc` streams leave your IO open

When reading or writing an IO that you supply with `IOStreams.stream(io)`, the `:gz`, `:gzip` and `:enc`
streams no longer close `io` when the block finishes, like every other stream. Paths are not affected,
since IOStreams opens and closes their files itself.

Fix: close the IO yourself once you are done with it, for example a pipe or socket that the other end
reads until it is closed.

### Paths compare by their full name

`==` and `<=>` now compare the full name of a path, as returned by `#to_s`, instead of only `#path`, so
paths in different S3 buckets, on different SFTP or HTTP hosts, or in different stores are no longer
equal, even with the same key or file name. A path also equals a `String` of its full name, such as
`IOStreams.path("/home/user/a.txt") == "/home/user/a.txt"`. Names are compared as given, so a relative
path does not equal its absolute path, and `"a.txt" == path` is false, since a `String` does not
compare equal to other objects.

Fix: to compare only the file names or keys, compare `#path`, for example `a.path == b.path`.

### `#path` is read-only

`Path#path=` is no longer public, so changing the name of an existing path raises `NoMethodError`.
A path is a `Hash` key for its location, so changing it in place meant it could no longer be found in
a `Hash` or `Set` that held it.

Fix: create a new path instead. `#join` and `#directory` return a new path that keeps the settings of
the original, such as the S3 client or the SFTP credentials:

```ruby
root = IOStreams.path("s3://bucket/data", region: "us-east-1")

# Before
path      = root.join("in.csv")
path.path = "data/out.csv"

# After
path = root.join("out.csv")
```

### `#builder=` is not public

`#builder=` is no longer public on a path or a stream, so calling it raises `NoMethodError`. It takes
an internal object, so the only use outside IOStreams was `path.builder = nil`, to remove the streams
and options set with `#stream` or `#option`.

Fix: create the path again with `IOStreams.path`, which has no streams or options, or use the path
that `#join` or `#directory` returns, which does not keep them.

### Paths and streams are copied, not shared

`IOStreams.path(path)`, `IOStreams.stream(stream)` and `IOStreams.new(stream)` now return a copy of
the path or stream supplied, instead of the same object. `IOStreams.join` without any elements,
`IOStreams.root`, `IOStreams.roots`, and `Path#join` without any elements also return copies.
The copy keeps the streams and options, and is equal to the original with `==`, but changing it, for
example with `#stream` or `#option`, no longer changes the original, or a root path for the whole
process.

Fix: code that relied on changing the original through the returned object should keep and use the
returned object instead:

```ruby
# Before: also changed `path`
IOStreams.path(path).option(:pgp, passphrase: "secret")
path.read

# After
path = IOStreams.path(path).option(:pgp, passphrase: "secret")
path.read
```

To change the streams of a root, supply them each time the root is used, for example
`IOStreams.join("a.csv").stream(:none)`. Code that compares with `equal?` should compare with `==`.

### `IOStreams.add_root` returns a frozen path

`IOStreams.add_root` now freezes the root path it adds, and returns it, so changing the returned path,
for example with `#stream` or `#option`, raises `FrozenError` instead of changing the root for the
whole process.

Fix: change the copy that `IOStreams.root` or `IOStreams.join` returns instead, each time the root is
used:

```ruby
IOStreams.add_root(:exports, "s3://bucket/exports")

IOStreams.join("a.csv.pgp", root: :exports).option(:pgp, passphrase: "secret").write(data)
```

### Unknown S3 options raise `ArgumentError`

An option supplied to an S3 path, or in the query string of its url, that no S3 request accepts now
raises `ArgumentError` when the path is created, as does a request parameter that the path sets itself,
such as `key` or `bucket`. Each S3 request is supplied the options that it accepts, so for example
`acl` applies when writing and copying, and `request_payer` to every request, including `#exist?`,
`#size`, `#delete` and `#each_child`.

Fix: correct or remove the option.

### SFTP urls without a path are the root directory

`IOStreams.path("sftp://host")` is now the root directory `/`, like `sftp://host/`, so `#each_child`
lists `/` instead of the login directory. Previously the children it returned were in `/` regardless, so
reading a listed file read the wrong file. Reading, writing and `#join` already used `/`, so for example
`IOStreams.path("sftp://host").join("a.csv")` is still `/a.csv`. A path starting with `~` is now within
the login directory, as curl does, for example `sftp://host/~/data/a.csv`.

Fix: use `sftp://host/~` to list the login directory. On a server that confines users to their own
directory, which is then `/`, no change is needed. An allowed path that starts with `sftp://host/~/`
now refers to the login directory, not to a directory named `~`.

### SFTP and HTTP urls without a path end with `/`

`#to_s` of an SFTP or HTTP url without a path now ends with `/`, like the root of an S3 bucket,
`s3://bucket/`. For example `IOStreams.path("sftp://host").to_s` is `sftp://host/`, and
`IOStreams.path("https://host?a=1").to_s` is `https://host/?a=1`. Previously the url was returned as
supplied, so `sftp://host` and `sftp://host/` were not equal, although they are the same location.

Fix: compare paths with paths, such as `path == IOStreams.path("sftp://host")`, or compare with the
url ending with `/`.

### SFTP `each_child` is case-insensitive

`#each_child` on an SFTP path is now case-insensitive by default, like local and S3 paths, as documented, so
`"*.csv"` also returns `DATA.CSV`. Previously SFTP defaulted to `case_sensitive: true`.

Fix: supply `case_sensitive: true` where a pattern must match the case of the file names.

### SFTP `each_child` returns nothing for a missing directory

`#each_child` on an SFTP path now returns nothing when the path does not exist, or is a file, like local and S3
paths. Previously it raised `Net::SFTP::StatusException`. It also skips a directory below the path that cannot be
read, like `Dir.glob`, instead of raising. A path that exists but cannot be read still raises.

It now only lists the directories that the pattern can match within, so `"*.csv"` only lists the path's directory.
Previously every directory below the path was listed for every pattern, which was slow for a large tree.

Fix: where your code rescues `Net::SFTP::StatusException` from `#each_child` to detect a missing directory,
check for no children instead.

### S3 `each_child` returns directories

`#each_child` on an S3 path with `directories: true` now returns the directories within the keys, like local and
SFTP paths, such as `s3://bucket/a` and `s3://bucket/a/b` for the key `a/b/c.csv`. Previously it only returned
empty folders created with a key ending in `/`, only with a pattern that included `**`, and with the trailing `/`,
such as `s3://bucket/a/`. An empty folder is now returned without the trailing `/`.

Fix: where your code supplies `directories: true` on S3 paths, check that it handles the extra directories,
or remove the trailing `/` that it expected.

### Other `each_child` changes

* An exact name supplied to `#each_child` on an S3 path, such as `each_child("a.csv")`, is now yielded with its
  attributes, like the children that match a pattern.
* `IOStreams.each_child` with a name without any pattern characters, such as `"s3://bucket/data/a.csv"`, now
  yields the attributes for S3 and SFTP paths, and only yields a directory with `directories: true`.
  Previously it yielded only the path, and yielded a local directory regardless.
* Local `#each_child` now returns `nil`, like S3 and SFTP paths. Previously it returned an internal array of the
  names that it found.
* S3 and SFTP `#each_child` match a pattern the same way as local paths. A pattern is within the path even when
  it starts with the path's own name, so `IOStreams.path("s3://bucket/data").each_child("data/*.csv")` lists
  `s3://bucket/data/data/`, where it listed `s3://bucket/data/`. A backslash escapes the next character, so
  `each_child("a\\b.csv")` returns `ab.csv`, where S3 and SFTP looked for a name containing the backslash.

Fix: a block that takes a single argument is unaffected by the attributes. A lambda or method that takes
exactly one argument must accept the attributes, as it already had to for patterns. Do not use the
return value of `#each_child` with a block; collect the children in the block, or use `#children`.

### A local `~` is the home directory

A local file name of `~`, or starting with `~/`, is now within the current user's home directory, so
`IOStreams.path("~/data/example.csv")` is `/home/user/data/example.csv`. This matches an SFTP url, where
`sftp://hostname/~/data/example.csv` is within the login directory, so a configured path can change between local
files and SFTP without changing the code. Previously `~` was a directory called `~` in the current directory,
so files written to `~/data/example.csv` are in `./~/data/example.csv`. A warning is logged via `IOStreams.logger`
when the current directory contains a directory called `~`. A name such as `~user/a.csv` or `~$Book1.xlsx` is unchanged.

Fix: move any files that were written to the `~` directory, or use `./~/data/example.csv` to keep using it.

### A failed copy to S3 does not delete the target

`#copy_from` an S3 path no longer deletes the object when the copy fails. S3 only stores an object once its
upload completes, so a failed copy never leaves an incomplete object. The delete could instead remove a
complete object when only the response to its upload was lost, or an object that another writer created
during the copy.

Fix: none is needed in most cases. When the copy raises, the object is either unchanged or completely
replaced. Code that relied on a failed copy always removing the object should call `#delete` after
the error.

### HTTPS downloads are not redirected to HTTP

Reading an `https://` path no longer follows a redirect to an `http://` url, and raises
`IOStreams::Errors::CommunicationsFailure` instead. Previously the download continued over plain http,
where the data could be read or changed in transit.

Fix: read the `http://` url directly if plain http is acceptable for that server, or have the
server redirect to an `https://` url.

### `compressed?` and `encrypted?` follow the streams

`#compressed?` and `#encrypted?` now report whether a stream in the pipeline compresses or encrypts the
data, whether it was inferred from the file name or set with `#stream`. Previously they only checked the
last extension of the file name:

* `IOStreams.path("data.csv.gz.pgp").compressed?` is now `true`.
* `IOStreams.path("tempfile2527").stream(:gz).compressed?` is now `true`.
* `IOStreams.path("data.csv.gz").stream(:none).compressed?` is now `false`.

Compression within a PGP or `.enc` file is still not reported, since only the encrypted data records
whether it was compressed.

Fix: none is needed, unless code relied on the previous result, for example to decide whether to
compress data before it is encrypted.

### Extensions are registered as formats

`IOStreams.extensions` now returns the format registered for each built-in extension, such as
`IOStreams::Gzip` for `:gz`, instead of an `IOStreams::Extension` struct. A format answers
`reader_class` and `writer_class` as before, but not the methods of a struct, such as `to_a`, `to_h`,
`==` or `[]`. An extension registered with its reader and writer classes is still an
`IOStreams::Extension`, which is now frozen, so its setters, such as `writer_class=`, raise `FrozenError`.
Previously the setters changed the registered extension for the whole process.

An extension registered with just its reader and writer classes is neither compressed nor encrypted.
So after replacing a built-in extension that is, such as `:xlsx`, `:gz` or `:pgp`, with your own reader
and writer classes, `#compressed?` or `#encrypted?` is now `false` for its files. Previously both were
based on the file name.

Fix: use `reader_class` and `writer_class` instead of the methods of a struct, and
`IOStreams.register_extension` to change a registered extension. To replace the reader or writer of an
extension whose data is compressed or encrypted, register a format that says so, see
[Registering a custom extension](extensions#registering-a-custom-extension).

### A `.encode` file name does not apply the encode stream

The `:encode` stream converts the text that the application reads or writes, and is applied with
`#option` or `#stream`. A file name ending in `.encode`, such as `notes.encode`, no longer applies it,
since file names do not name it. Previously the data of such a file was read and written through it.

Fix: none is needed, unless a file name ending in `.encode` was used to apply the encode stream.
Apply it with `option(:encode, ...)` instead.

### The encode `cleaner` option is strict

A `cleaner` for the `:encode` stream that is neither the name of a built-in rule nor a Proc, such as the
String `"printable"`, raises `ArgumentError`. Previously it was ignored, so the data was not cleansed.

Fix: supply the name of a built-in rule as a Symbol, such as `cleaner: :printable`, for example with
`.to_sym` when it comes from configuration.

## Upgrading to v2.1

v2.1 is a security release, and is backward compatible except for `IOStreams::Pgp.delete_keys`,
described below. Most applications upgrade without any code changes. The changes that would break
existing code were postponed to v3.0, and log a warning in v2.1. See [Upgrading to v3.0](#upgrading-to-v30).

### Changes that may need code changes

#### PGP `delete_keys` requires an email or key id

`IOStreams::Pgp.delete_keys` raises `ArgumentError` unless an `email:` or `key_id:` is supplied.
Previously, on GnuPG 2.1 and later, calling it without either deleted every key in the keyring, and
with `private: true`, every secret key. This is the only breaking change in v2.1, since that could
not be undone. To delete several keys, call it once for each key, for example for each key returned
by `IOStreams::Pgp.list_keys`.

#### SFTP `#each_child` requires a known host key

`#each_child` on an SFTP path now verifies the server's host key, the same way reading and writing
already did. Previously it trusted a host key the first time it was seen. If listing files now
fails, supply the server's host key with the `HostKey` ssh option, or add it to the `known_hosts`
file of the user running the application. See [SFTP](path#sftp-sftp).

`#each_child` now also supports the `HostKey`, `IdentityKey` and `IdentityFile` ssh options, and
some others. Previously any ssh option made it raise `ArgumentError`. Any ssh option it does not
support raises `ArgumentError`.

#### Other changes in behavior

- SFTP `#each_child` lists the files in the path's directory. Previously it ignored the path and
  listed the login directory, so `IOStreams.path("sftp://host/data/in").each_child("*.csv")`
  listed `~/*.csv`, returning paths such as `/a.csv`. A url without a path, such as `sftp://host`,
  still lists the login directory.
- `Path#join` and `IOStreams.join` only return an element unchanged when it is the path itself or
  is inside it. Previously any element that started with the same characters was returned as-is,
  so `IOStreams.path("s3://bucket/reports").join("reports_2024.csv")` gave
  `s3://bucket/reports_2024.csv`, instead of `s3://bucket/reports/reports_2024.csv`.
- When writing PSV or fixed width files, a line break within a value is replaced with a space, so
  that a value can no longer start a separate record.
- Internal temp files are created so that only the current user can read them.
- When reading lines, newlines within quoted values are kept within the line when the tabular format
  quotes its values, such as CSV. Previously this depended on whether the file name contained `.csv`,
  so `.format(:psv)` on a `.csv` file still joined quoted lines, and `.format(:csv)` on a stream
  without a file name did not.
- An `ArgumentError` for an option that a stream does not accept now says which direction the option
  belongs to, or lists the valid options. Previously it was Ruby's `unknown keyword` error.

### Security checklist

When upgrading, review how your application uses IOStreams for the following documented security
issues. Each one depends on how the application is written, so upgrading alone does not fix it.

#### File names from untrusted input

If a user, a job, or any other untrusted input can supply a file name, it can also supply `..`
or an absolute path, and read or overwrite any file that the process can access. `IOStreams.join`
and root paths do not prevent this.

New in v2.1, add **allowed paths** in an initializer, so that accessing any other path raises
`IOStreams::Errors::AccessDenied`:

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
IOStreams.add_allowed_path("s3://my-app-bucket-name/export")
~~~

Once any allowed path is added, every path IOStreams accesses in the process must be within one of
them, so add every location that your application reads or writes. See
[Restricting access with allowed paths](path#restricting-access-with-allowed-paths).

#### Untrusted names in S3 urls

Any query string in an S3 url is added to the S3 request parameters. Do not interpolate an
untrusted file name into the url, since a name such as `file.csv?acl=public-read` would set
request parameters. Join it onto the path instead. See [AWS S3](path#aws-s3-s3).

~~~ruby
# Unsafe
IOStreams.path("s3://my-bucket-name/uploads/#{untrusted_name}")

# Safe
IOStreams.path("s3://my-bucket-name/uploads").join(untrusted_name)
~~~

#### Credentials in HTTP and SFTP urls

A username and password supplied in an HTTP or SFTP url remain part of it, so `#to_s` returns
them, as does any log or error message that includes the path. Supply them with the `username:`
and `password:` arguments instead, and log `#display_name`, which never includes them:

~~~ruby
# Returns the password from #to_s
IOStreams.path("sftp://jack:secret@sftp.example.org/file.csv")

# Does not
IOStreams.path("sftp://sftp.example.org/file.csv", username: "jack", password: "secret")
~~~

#### Untrusted HTTP urls

When any part of an HTTP url comes from untrusted input, an attacker can point it at internal
services or cloud metadata endpoints (Server Side Request Forgery), either directly or with a
redirect. Use `allow_hosts`, `http_redirect_count` and `maximum_file_size`, or allowed paths, which
also check every redirect. See [Security: untrusted URLs (SSRF)](path#security-untrusted-urls-ssrf).

#### Processing PGP files before they are verified

By default IOStreams passes the decrypted contents of a PGP file to your block as gpg decrypts it.
gpg can only check the file's integrity and signature once it has read the whole file, so a
tampered file is only rejected after your block has processed its contents. Either do not commit
any side effects until the block returns, for example by using a database transaction, or supply
the `verify_first` option, new in v2.1. See
[Verifying a file before processing it](pgp#verifying-a-file-before-processing-it).

~~~ruby
path.option(:pgp, passphrase: "receiver_passphrase", verify_first: true)
~~~

#### Importing and trusting PGP keys

`import_and_trust` and the writer's `import_and_trust_key` option trust a key at the Ultimate
level by default, so only use them with keys received from a verified, trusted source. When a key
cannot be fully verified, supply a lower `trust_level:` to `import_and_trust`, or a lower
`import_and_trust_level` option to the writer. See
[Trust level](pgp#trust-level).

In v2.1, `import_and_trust_key` encrypts to the imported key's fingerprint on GnuPG 2.1 and later.
Previously it encrypted to the key's email address, so if your keyring holds another key with the
same email address, that key could have been used instead. Check your keyring for duplicate email
addresses.

#### PGP files without integrity protection

Only enable `ignore_mdc_error` for files from a trusted source, since without MDC the decrypted
contents are not protected against tampering. See
[Reading legacy files without MDC integrity protection](pgp#reading-legacy-files-without-mdc-integrity-protection).

#### Column restrictions on uploaded files

In v2.1, by default, `allowed_columns` and `required_columns` are ignored for JSON input. Since the format
is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypasses them.
If your application relies on them to restrict which columns an upload can set, apply them to every
input in an initializer, new in v2.1, and check whether any uploads were affected:

~~~ruby
IOStreams.enforce_column_restrictions = true
~~~

See [Column restrictions apply to every input](#column-restrictions-apply-to-every-input) for what
it changes.

## Upgrading to v2.0

v2.0 is a major release with breaking changes:

- **Ruby 3.2 or later is required.**
- **Writing Zip files requires the `zip_kit` gem.** The retired `zip_tricks` gem has been replaced
  by its successor, `zip_kit`. If your application writes Zip files, replace `gem "zip_tricks"` with
  `gem "zip_kit"` in your Gemfile. Reading Zip files is unaffected.
- **The deprecated pre-v1.6 API has been removed**, including the `IOStreams::Deprecated` mix-in.
  Move any code still using it to the `IOStreams.path` and `IOStreams.stream` API.
- **The deprecated PGP writer `compression:` option has been removed.** Use `compress:` instead,
  available since v1.11.0.
- **`IOStreams::Pgp.logger` and `IOStreams::Pgp.logger=` have been removed.** Logging is configured
  for the whole library with `IOStreams.logger=`. See [logger](config#logger).

## Upgrading from before v1.6

The pre-v1.6 API was deprecated in v1.6 and removed in v2.0. Upgrade to v1.11 first, move all code to
the `IOStreams.path` and `IOStreams.stream` API, and then upgrade to v2.
