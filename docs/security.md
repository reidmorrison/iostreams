---
layout: default
title: Security
description: >-
  Restricting the files that IOStreams can access, keeping credentials out of logs,
  untrusted urls, uploaded files, and processing PGP files safely.
---

**Contents**

* TOC
{:toc}

IOStreams reads and writes whatever its paths name, with the access of the process. When any part of a path, url or
file comes from outside the application, such as from a user, a partner, or a job's configuration, review the
settings on this page. None of them is on by default, since each one depends on how the application uses IOStreams,
apart from the time limit of a `pattern`, see [Untrusted schemas and patterns](#untrusted-schemas-and-patterns).

## Allowed paths

If a user, a job, or any other untrusted input can supply a file name, it can also supply `..` or an absolute path,
and read or overwrite any file that the process can access. [Root paths](path#using-root-paths) make paths easy to
build, but they do not stop a path from leaving the root, for example `IOStreams.join("../../etc/passwd")`.

Add the allowed paths in an initializer, where untrusted input cannot change them:

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
IOStreams.add_allowed_path("s3://my-app-bucket-name/export")
IOStreams.add_allowed_path("sftp://sftp.example.org/outbound")
IOStreams.add_allowed_path("https://reports.example.org/daily")
~~~

Once any allowed path has been added, reading, writing, listing, deleting or otherwise accessing a path that is not
within one of them raises `IOStreams::Errors::AccessDenied`. So add every location that the application reads or
writes.

~~~ruby
IOStreams.path("/var/my_app/uploads/file.csv").read
# => "..."

IOStreams.path("/var/my_app/uploads/../secrets.yml").read
# raises IOStreams::Errors::AccessDenied

# Check without raising:
IOStreams.path("/etc/passwd").allowed?
# => false
~~~

Paths are normalized before they are compared:

* Local file names are resolved to their real path, so neither `..` nor a symbolic link can leave an allowed path. A
  relative allowed path is resolved against the current directory when it is added.
* S3 and Google Cloud Storage paths must be in the same bucket, of the same scheme, so an allowed `gs://` path does
  not allow the `s3://` path of the same bucket. Keys with `.` or `..` segments are denied, since some services that
  implement the S3 API resolve them.
* SFTP and HTTP paths must have the same host and port, and for HTTP the same scheme. `.` and `..` are resolved the way
  the server resolves them, and every HTTP redirect is checked too.

Notes:

* By default there are no allowed paths, and every path can be accessed.
* `#each_child` skips the children that are not within the allowed paths, such as a symbolic link to a file elsewhere.
* The temp files of `IOStreams.temp_file` can always be accessed.
* `IOStreams.allowed_paths` returns the normalized allowed paths, and `IOStreams.delete_allowed_path` removes one.
* The paths of a scheme registered with `IOStreams.register_scheme` are denied, unless its path class says where it
  is, see [Extending IOStreams](extending#allowed-paths-and-credentials).
* A local file could be replaced with a symbolic link after it is checked, but before it is opened. Allowed paths do
  not prevent this, so do not allow paths where untrusted users can create files.
* `IOStreams::Errors::AccessDenied` is not an `IOStreams::Errors::PermissionDenied`, which the storage raises, see
  [Errors](errors), so that rescuing a failure of the storage does not hide a denied path.

## Untrusted names in urls

The query string of an S3 url sets the options of its requests, such as `?acl=public-read`. Never interpolate an
untrusted name into a url, since a name such as `file.csv?acl=public-read` would set them, and the name `../a.csv`
would leave the directory. Join the name onto the path instead, which treats it as a name:

~~~ruby
# Unsafe
IOStreams.path("s3://my-bucket-name/uploads/#{untrusted_name}")

# Safe
IOStreams.path("s3://my-bucket-name/uploads").join(untrusted_name)
~~~

## Credentials in urls and options

A user name and password in an SFTP or HTTP url remain part of it, so `#to_s` returns them, as does anything that
logs the path with it. Supply them with the `username:` and `password:` options instead, and log `#display_name`, which
never includes them:

~~~ruby
IOStreams.path("sftp://jack:secret@sftp.example.org/file.csv").to_s
# => "sftp://jack:secret@sftp.example.org/file.csv"

IOStreams.path("sftp://jack:secret@sftp.example.org/file.csv").display_name
# => "sftp://sftp.example.org/file.csv"

IOStreams.path("sftp://sftp.example.org/file.csv", username: "jack", password: "secret")
~~~

IOStreams keeps credentials out of what it displays:

* `#display_name` removes the user name, password and query of an SFTP or HTTP url, which can hold credentials, such
  as the signature of a pre-signed url. IOStreams uses it in the messages of the errors that it raises, and in the
  messages that it logs, such as for each HTTP redirect that it follows.
* `#inspect` on a path or stream shows `#display_name`, and replaces the value of each option that holds a secret, such
  as a PGP `passphrase`, with `"[FILTERED]"`.
* `IOStreams.redact_path_options(url, options)` and `IOStreams.redact_stream_options(streams)` return options with each
  secret replaced, for an application that stores a url and its options, or its streams, to create the path later, and
  displays them:

~~~ruby
IOStreams.redact_path_options("sftp://example.org/a.csv", username: "jack", password: "secret")
# => {username: "jack", password: "[FILTERED]"}

IOStreams.redact_stream_options(pgp: {passphrase: "secret", recipient: "a@b.org"})
# => {pgp: {passphrase: "[FILTERED]", recipient: "a@b.org"}}
~~~

Each path class and stream declares the options that hold secrets: the SFTP `password` and `IdentityKey`, the S3
`secret_access_key` and customer encryption keys, the Google Cloud Storage `secret_access_key`, the HTTP `password`, `parameters` and cookie headers, and the PGP
passphrases. As a precaution, any option whose name contains `passphrase`, `password`, `secret`, `token`,
`credential`, `auth`, `apikey` or `privatekey` is replaced too, whatever its case, and with or without `_` and `-`,
such as the headers `Authorization` and `X-Api-Key`, including within a Hash option, such as `ssh_options:` or
`headers:`.

## Untrusted HTTP urls

Reading an HTTP(S) path makes the application send a request to the host that the url names. When the url, or any
part of it, comes from untrusted input, an attacker can point it at an internal service, or at a cloud metadata
endpoint, which is called Server Side Request Forgery (SSRF). Since the remote server chooses where a redirect goes,
checking only the url that is supplied is not enough. Limit what a request can reach:

~~~ruby
# Only contact these hosts, including after a redirect.
IOStreams.path("https://supplier.example.com/report.csv", allow_hosts: ["supplier.example.com"]).read

# Follow no redirects.
IOStreams.path(untrusted_url, http_redirect_count: 0).read

# Limit the size of the download.
IOStreams.path(untrusted_url, maximum_file_size: 50 * 1024 * 1024).read
~~~

`maximum_file_size:` limits the bytes received, and the size of the file once IOStreams decompresses a response
that the server compressed, so a small response that decompresses to a huge file is stopped too.

Allowed paths also check every redirect. Credentials, and the `headers:` supplied, are only ever sent to the original
host: they are not sent again after a redirect to another scheme, host or port, apart from an `Accept-Encoding`, which
holds no credential. A redirect from `https` to `http` is
not followed, so that the data cannot be read or changed in transit. When writing or deleting, a redirect is only
followed to the same scheme, host and port, so that it cannot send the data to another server, or delete a file on it.
For stronger guarantees, send these requests through an egress proxy, or a network policy, that blocks private,
loopback and link-local addresses.

## Uploaded CSV, JSON and Excel files {#uploaded-tabular-files}

A file uploaded by a user can have any columns, and since the format is usually taken from the file name, renaming an
upload from `.csv` to `.json` changes how it is read. Describe the columns that the application accepts with a
[contract](contracts), which checks the columns of every file it reads, whatever its format:

~~~ruby
class ContactUpload < IOStreams::Contract
  # Skip any other columns, rather than raising for them.
  fields_match "subset"

  field :email, :string, required: true
  field :name,  :string
end

IOStreams.path(upload_path).as(ContactUpload).each(:hash) do |contact|
  Contact.create!(contact)
end
~~~

The records that are read only hold the fields of the contract, so an upload cannot set any other column. A file
without a required field raises `IOStreams::Errors::InvalidHeader` before the first record, and a value that is not of
the type of its field raises `IOStreams::Errors::InvalidValue`, naming its line. To show the user every problem at
once, check the columns in the request that accepts the upload with `#contract_errors`, and list each invalid row with
`on_invalid:`, see [Checking a source](contracts#checking-a-source-before-the-work-starts) and
[Report invalid rows](contracts#report-invalid-rows-and-carry-on). See also [fieldsMatch](schemas#fieldsmatch) and
[Required fields](schemas#required-fields).

An uploaded spreadsheet is a zip file of XML, which IOStreams reads without an XML gem. It rejects a document type
declaration, so a spreadsheet cannot expand entities or read other files, reads only the parts within the zip file,
checks the size and CRC32 of each part, and holds each row and value as it streams the worksheet, with a row of at
most Excel's 16,384 columns. What it does not limit is the size of the upload once decompressed: a small zip file can
hold parts that decompress to gigabytes, which IOStreams reads, including parts that it does not use, as it checks
them, and its rows, read as lines, are CSV text in a temp file, of up to 16,384 values for each row. Limit the size of
the upload, and run the job that reads it with a time limit, as for any other upload.

## Untrusted schemas and patterns

The `pattern` constraint of a field is a Ruby regular expression that each value must match, see
[Constraints](schemas#constraints). Some patterns, such as one with a backreference, `(?:(a+)\1?)+`, can take
exponentially longer to match as a value grows, so a value of a few dozen characters could hold up a read or write for
minutes. This matters when a user supplies the schema, such as a Table Schema uploaded with its data, or when a
developer's pattern has a backreference or lookaround and users supply the values.

So a value that takes longer than `IOStreams.pattern_timeout` to match, 0.1 seconds by default, raises
`IOStreams::Errors::InvalidValue`, naming the field, such as
`Field "code": "aaaa...!" took longer than 0.1 seconds to match its pattern, /(?:(a+)\1?)+/`, as any other value that
does not meet a constraint does, so `on_invalid:` can report it and carry on. With `on_invalid:`, each such row can
still take that long, so keep the limit short when the values come from a user.

The limit is the time that passes while one value is matched, not the time the processor spends on it, so a lawful
match of a very large value, such as a long text cell, on a busy machine can exceed it too, and be rejected. Raise the
limit when the values can be that large.

Set it once at startup, before any schema or contract is defined, since each reads it when it is built and keeps the
limit it was built with. A contract class builds its schema when its body runs, so set it in an initializer that runs
before the contract classes load, such as before `Bundler.require` loads a gem that defines them:

~~~ruby
# config/initializers/iostreams.rb
IOStreams.pattern_timeout = 0.05
~~~

When `Regexp.timeout` is also set, the stricter of the two applies, since a pattern's own limit would otherwise replace
it. Set `IOStreams.pattern_timeout` to `nil` to leave the time of a pattern to `Regexp.timeout`, which has no limit by
default. The limit is enforced on both CRuby and JRuby.

To reject a slow pattern before reading anything, check a schema that a user supplies with `Regexp.linear_time?`,
which is true for a pattern that CRuby matches in a time that grows only with the length of the value. JRuby answers
false for every pattern, so this check rejects them all there:

~~~ruby
schema["fields"].each do |field|
  pattern = field.dig("constraints", "pattern")
  raise(ArgumentError, "Field #{field['name']}: pattern is too slow") if pattern && !Regexp.linear_time?(pattern)
end
~~~

## Exporting the rows of a tenant

A query that `IOStreams.stream(relation)` or `copy_from(relation)` reads as one query runs on a connection of its own,
checked out of the pool, rather than on the connection of the caller. So state that the application set on its own
connection with a statement, such as PostgreSQL's `SET search_path` for a schema of each tenant, `SET ROLE`, a setting
such as `app.tenant_id` that a row-level security policy reads, or MySQL's `USE`, does not apply to the rows read, which
could then be those of another tenant. IOStreams raises `ArgumentError` when the `current_user` or `search_path` of
PostgreSQL, or the database or `CURRENT_ROLE()` of MySQL 8.0 or MariaDB 10.0.5 and later, differs between the
connection of the read and the one that the caller leases. It cannot see a setting of the application, a session
variable, or state set on a connection that the caller no longer holds, such as within a `with_connection` that has
returned it, which stays on that connection of the pool for the next query, such as the read. Set state for one task
with `SET LOCAL` within a transaction, or for every connection in a checkout callback of Active Record, put the tenant
into the query as a condition, or read the relation in batches, which run on the connection of the caller. See
[Session state, tenants and row security](queries#session-state).

## PGP

* **Verify a file before processing it.** IOStreams passes the decrypted data of a PGP file to your block as gpg
  decrypts it, but gpg can only check its integrity and signature once it has read the whole file, so a tampered file
  is only rejected after the block has processed it. Either commit nothing until the block returns, such as within a
  database transaction, or supply `verify_first: true`, which checks the file before the block runs. See
  [Verifying a file before processing it](pgp#verifying-a-file-before-processing-it).
* **Require the sender's signature** with the reader's `signer` option, so that only a file signed by that key is
  accepted, see [PGP](pgp). A signature by a key that has been revoked or has expired is rejected, also for a key
  supplied with `import_and_trust_key`, so import a partner's revocation as soon as they publish it.
* **Import and trust only verified keys.** `IOStreams::Pgp.import_and_trust` and the `import_and_trust_key` option
  trust a key at the Ultimate level by default, so only use them for keys from a verified source, or supply a lower
  trust level. See [Trust level](pgp#trust-level).
* **Integrity protection.** Only supply `ignore_mdc_error` for files from a trusted source, since without MDC the data
  is not protected against tampering. See
  [Reading legacy files without MDC integrity protection](pgp#reading-legacy-files-without-mdc-integrity-protection).

## Temp files

A few formats can only be read from a local file, such as a zip file or a spreadsheet, so IOStreams copies one that is
stored elsewhere, or within another stream, such as `data.csv.zip.pgp`, into a temp file first. That temp file can hold
data that was decrypted. Temp files are created in `IOStreams.temp_dir`, so that only the current user can read them,
and are deleted as soon as they have been read or written. To keep them off a shared disk, set `IOStreams.temp_dir` to
a private or encrypted volume. See [When temp files are used](config#when-temp-files-are-used).
