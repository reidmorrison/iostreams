---
layout: default
title: Configuring IOStreams
description: >-
  Keeping paths in configuration so the same code targets different storage per
  environment, named roots via IOStreams.add_root, the temp directory, when temp
  files are used, the logger, and the process-wide settings.
---

**Contents**

* TOC
{:toc}

Most applications set up IOStreams once, at startup, in an initializer: where their files are stored, with
[roots](#add_root), where temp files go, with [temp_dir](#temp_dir), and where IOStreams logs, with [logger](#logger).
[Process-wide settings](#process-wide-settings) lists them all.

## Paths are configuration

A path or url is configuration, not code. Keep it in an environment variable or a centralized configuration
system, and pass it to IOStreams, so that the exact same application code runs against local files in
development and a completely different file store in staging or production.

~~~ruby
# Development: EXPORT_PATH=~/exports/daily.csv
# Staging:     EXPORT_PATH=sftp://staging.example.org/~/exports/daily.csv
# Production:  EXPORT_PATH=s3://my-bucket/exports/daily.csv
IOStreams.path(ENV.fetch("EXPORT_PATH")).write(report)
~~~

This also helps when infrastructure changes. For example, while migrating production from on-premises
servers to the cloud, the on-premises instance can keep reading and writing local files while the cloud
instance uses S3, both running the same release with only their configuration differing.

The same path written for each file store refers to the equivalent place. For example `~/exports` is within
the home directory, and `sftp://hostname/~/exports` is within the login directory on the SFTP server.

To keep code independent of where its files are stored:

* Use the methods on the path, such as `exist?`, `each_child`, `move_to`, `delete`, `reader` and `writer`,
  rather than passing `path.to_s` to `File` or `Dir`, which only work with local files.
* Do not check the scheme of a path to decide what to do with it.
* Rescue the kind of failure, such as `IOStreams::Errors::NotFound` for a file that does not exist, rather than the
  exception that one storage raises, such as `Errno::ENOENT`, see [Errors](errors).
* Keep credentials in configuration too, for example the AWS environment variables or credential files for S3, the
  HMAC key of a root for Google Cloud Storage, see [Credentials](path#gcs-credentials), and the ssh config for SFTP.

When an application uses several locations, [roots](#add_root) give them names, and each root can be set from
configuration:

~~~ruby
IOStreams.add_root(:default, ENV.fetch("FILES_ROOT"))
IOStreams.join("exports", "daily.csv").write(report)
~~~

## add_root

A root names a location once, at startup, such as the directory or bucket that the application keeps its files in,
so that the code joins file names to it, and never names the store. Add the roots in an initializer:

~~~ruby
# config/initializers/iostreams.rb
IOStreams.add_root(:default, "/var/my_app/files")
IOStreams.add_root(:uploads, "/var/my_app/uploads")
~~~

`IOStreams.join` joins names to the `:default` root, or to the root that `root:` names:

~~~ruby
IOStreams.join("exports", "daily.csv").to_s
# => "/var/my_app/files/exports/daily.csv"

IOStreams.join("orders.csv", root: :uploads).to_s
# => "/var/my_app/uploads/orders.csv"

IOStreams.root(:uploads).to_s
# => "/var/my_app/uploads"
~~~

In production the same initializer can name S3 buckets instead, such as `"s3://my-app-bucket/uploads"`, or read each
location from configuration, such as `ENV.fetch("UPLOADS_ROOT")`, so that the code that reads and writes the files does
not change. In development the roots can all point to one local directory. See
[Using root paths](path#using-root-paths).

A root is shared by the whole process, so `IOStreams.add_root` freezes it, and returns it frozen. `IOStreams.root`,
`IOStreams.roots` and `IOStreams.join` return copies of it, which can be changed without changing the root. A path
joined to a root keeps the arguments of the root, such as its credentials, S3 options or ssh options, but not the
streams, options, encoding, format, schema or contract set on the root, which describe the file that the root names,
or how it is read, so set those on each path:

~~~ruby
IOStreams.add_root(:partner, IOStreams.path("sftp://sftp.example.org/outbound", username: "jack", password: "secret"))

IOStreams.join("daily.csv.pgp", root: :partner).option(:pgp, recipient: "partner@example.org").write(report)
~~~

## temp_dir

IOStreams reads and writes files of any size a block at a time, and most streams never touch the disk.
For some storage locations and formats IOStreams copies the data into a temp file under the covers, see
[When temp files are used](#when-temp-files-are-used). Each temp file holds a whole file, so when working with
large files the standard temp location can be too small, for example to download a large file from SFTP, or to
copy one from SFTP to another SFTP server, which holds two temp files at once.

By default IOStreams looks up the location to store temp files in the following order:
* `ENV['TMPDIR']`
* `ENV['TMP']`
* `ENV['TEMP']`
* `Etc.systmpdir`
* `/tmp` (if it exists)
* Otherwise `.`

To set the temp file location explicitly:

~~~ruby
IOStreams.temp_dir = "/var/really_big_temp"
~~~

### When temp files are used

The application reads and writes a block at a time wherever the file is stored, but some S3, SFTP and HTTP
transfers go through a temp file that holds the whole file:

| Path | Reading | Writing | Why |
| --- | --- | --- | --- |
| Local file | No temp file | No temp file | |
| AWS S3 | No temp file: requests the object 8MB at a time, as the application reads it. With the `range` or `part_number` option, downloads the object into a temp file before the block is called | No temp file: uploads the data as it is written, in parts of 8MB or more. With an option that describes the whole object, such as `content_md5` or `checksum_crc32`, writes into a temp file, which is uploaded once the block completes | A single download is pushed by the AWS SDK, so the bytes chosen by `range` or `part_number` are downloaded first. An option that describes the whole object cannot be supplied to each part |
| Google Cloud Storage | No temp file: requests the object 8MB at a time, as the application reads it | No temp file: uploads the data as it is written, in parts of 8MB or more | |
| SFTP | Downloads the file into a temp file before the block is called | Writes into a temp file, which is uploaded once the block completes | The `sftp` program transfers local files, and only uploads a regular file |
| HTTP(S) | No temp file: reads the response one chunk at a time, as the application reads it | Writes into a temp file, which is uploaded with a single PUT once the block completes | An upload needs its `Content-Length`, and is sent again after a `307` or `308` redirect |
| An IO supplied to `IOStreams.stream` | No temp file | No temp file | |

Most formats are read and written as the data passes through them. A format that only works on whole files
reads or writes a local file directly when it has one: a local path, a `File` supplied to `IOStreams.stream`, or
the temp file of an SFTP path. Otherwise its data is copied into a temp file first, for example when
reading the zip file within `data.csv.zip.pgp`, which comes from `gpg` as it decrypts the file, or a zip file
supplied in a `StringIO`.

| Format | Reading | Writing | Why |
| --- | --- | --- | --- |
| `.gz`, `.gzip`, `.bz2`, `.zst`, `.enc` | No temp file | No temp file | Streamed |
| `.zip` | No temp file for a local file, otherwise a temp file holding the zip file | No temp file | A zip file lists its contents at its end, so reading one needs the whole file. Writing streams the zip file |
| `.xlsx`, `.xlsm` | When it is not a local file, a temp file holding the spreadsheet, and in the `:line` mode, or a copy without a mode, a temp file holding the rows as CSV | No temp file | The `creek` gem reads a spreadsheet file, and returns its rows to a block, which its rows and records read as they are, while its lines are converted into CSV for the application to read. Writing streams the spreadsheet with `xlsxtream` |
| `.pgp`, `.gpg` | No temp file. With `verify_first: true`, a temp file holding the decrypted data | No temp file | `gpg` reads a local file itself, and any other stream through its stdin, and writes through its stdout |
| `.parquet` | No temp file for a local file, otherwise a temp file holding the Parquet file | A temp file holding the Parquet file, which is copied to the path once the block completes | A Parquet file records its columns at its end, and the `parquet` gem writes the whole file before it can be copied |

So a zip or spreadsheet stream only has a local file when it is the stream closest to the stored data: the
last extension in the file name, or the last stream set with `#stream`. `#pipeline` lists the streams in order
from the application to the stored data:

~~~ruby
IOStreams.path("sftp://example.org/data.csv.zip.pgp").pipeline
# => {zip: {}, pgp: {}}
# Reading: gpg decrypts the SFTP download, and the zip file that it decrypts is copied into a temp file.
~~~

For example:

| Path | Temp files when reading | Temp files when writing |
| --- | --- | --- |
| `data.csv`, `data.csv.gz`, `data.csv.zip`, `data.csv.pgp`, `data.csv.pgp.gz` | None | None |
| `data.xlsx` | Rows and records: none. Lines: 1, the rows as CSV | None |
| `data.csv.pgp`, read with `verify_first: true` | 1: the decrypted data | None |
| `data.csv.zip.pgp` | 1: the decrypted zip file | None |
| `s3://bucket/data.csv`, `s3://bucket/data.csv.pgp` | None | None |
| `s3://bucket/data.csv.zip` | 1: the zip file | None |
| `s3://bucket/data.xlsx` | Rows and records: 1, the spreadsheet. Lines: 2, the spreadsheet, and the rows as CSV | None |
| `sftp://example.org/data.csv.zip.pgp` | 2: the download, and the decrypted zip file | 1: the upload |
| `IOStreams.stream(StringIO.new(data)).stream(:pgp)` | None | None |
| `IOStreams.stream(StringIO.new(data)).stream(:zip)` | 1: the zip file | None |

To see the temp files that IOStreams uses, set the [logger](#logger) to the debug level. Each temp file is logged
when it is created, with what it holds, and when it is deleted, with its size:

~~~
Created temp file /tmp/iostreams-sftp-reader20261008-41-1x5yq2 for the download of sftp://example.org/data.csv.zip.pgp
Created temp file /tmp/iostreams_reader20261008-41-9kq4ht for a copy of the input of IOStreams::Zip::Reader, which only reads files
Deleting temp file /tmp/iostreams_reader20261008-41-9kq4ht, which held 5242880 bytes
Deleting temp file /tmp/iostreams-sftp-reader20261008-41-1x5yq2, which held 5251187 bytes
~~~

Notes:
* `#copy_from` and `#copy_to` read the source while they write the target, so copying from SFTP to SFTP or
  HTTP holds two temp files at once, each holding the whole file: the download and the upload. S3 copies an
  object to another S3 path itself, without a temp file, when copying with `convert: false`, or with `#move_to`, for
  an object smaller than 5GB, and so does Google Cloud Storage from one `gs://` path to another.
* An SFTP `IdentityKey` or `HostKey`, and a PGP `import_and_trust_key` when writing, are written into small temp
  files, since `sftp` and `gpg` read them from files.
* Only the current user can read a temp file, and it is deleted when the block returns or raises. A temp file can
  hold decrypted data, such as the zip file within a `.zip.pgp` file, or the contents of a PGP file read with
  `verify_first: true`, so keep `temp_dir` on storage that is protected as well as the data.

### temp_file

To work with a temporary file directly, `IOStreams.temp_file` yields a path inside `temp_dir`
and deletes the file when the block completes:

~~~ruby
IOStreams.temp_file("export", ".csv") do |path|
  path.write("Hello World")
  # ... use the temp file ...
end
# The temp file has been deleted.
~~~

The first argument is a base file name to include in the generated temp file name, and the
optional second argument is the file extension. Like any other path, the streams that the extension
implies are applied, so writing to a temp file with the extension `.csv.gz` compresses the data. Call
`#raw` on the path to read or write the data as it is stored.

## logger

IOStreams can log debug information, such as the external commands it runs for PGP and SFTP, and each temp
file that it uses, see [When temp files are used](#when-temp-files-are-used).

When [Semantic Logger](https://logger.reidmorrison.com) is loaded before IOStreams, IOStreams logs to it without
any additional configuration.

To use a different logger, or to log when Semantic Logger is not present, assign any logger that
responds to the standard logging methods:

~~~ruby
require "logger"
IOStreams.logger = Logger.new($stdout)
~~~

To disable logging entirely, set the logger to `nil`:

~~~ruby
IOStreams.logger = nil
~~~

## Process-wide settings

Each of these applies to the whole process, so set them once, in an initializer, at startup:

| Setting | What it does | See |
|---------|--------------|-----|
| `IOStreams.add_root(name, path)` | Names a location that `IOStreams.join` joins paths onto | [add_root](#add_root) |
| `IOStreams.add_allowed_path(path)` | Restricts IOStreams to the allowed paths | [Allowed paths](security#allowed-paths) |
| `IOStreams.temp_dir = dir` | Where IOStreams creates its temp files | [temp_dir](#temp_dir) |
| `IOStreams.logger = logger` | Where IOStreams logs | [logger](#logger) |
| `IOStreams.register_extension(extension, format)` | Reads and writes a file name extension with a format | [Extending IOStreams](extending#registering-a-format) |
| `IOStreams.register_scheme(scheme, path_class)` | Reads and writes the urls of a scheme with a path class | [Extending IOStreams](extending#registering-a-storage-scheme) |
| `IOStreams::Pgp.executable = "gpg2"` | The name or path of the `gpg` program | [PGP](pgp) |
| `IOStreams::Pgp::Writer.default_signer = email` and `.default_signer_passphrase = passphrase` | Signs every PGP file written | [PGP](pgp) |
| `IOStreams::Pgp::Writer.audit_recipient = email` | Also encrypts every PGP file written for this recipient | [PGP](pgp) |
| `IOStreams::Pgp::Reader.default_passphrase = passphrase` | The passphrase of the private key when a read supplies none | [PGP](pgp) |
