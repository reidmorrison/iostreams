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

v3.0 is a major release with the breaking changes that were postponed from v2.1. In v2.1 each one
logged a warning via `IOStreams.logger` when it would change the result, so check your logs from
v2.1 for them before upgrading. It also includes bug fixes that change behavior that existing code
may depend on, described at the end of this section.

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

The BZip2 reader and writer now raise `ArgumentError` for an option they do not accept, like every
other stream. Previously they ignored it. They accept `autoclose`, `first_only` and `small` when
reading, and `autoclose`, `block_size` and `work_factor` when writing.

Fix: remove the option, or use a separate path for reading and for writing. See
[Reading and writing need separate options](streams#reading-and-writing-need-separate-options).

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

### A `+` in an S3 or SFTP url is kept

A `+` in the path of an S3 or SFTP url is now kept, so `IOStreams.path("s3://bucket/a+b.csv")` reads
the key `a+b.csv`. Previously it was decoded as a space, and read the key `a b.csv`.

Fix: use a space, or `%20`, in the url for a space.

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
and `password:` arguments instead:

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
