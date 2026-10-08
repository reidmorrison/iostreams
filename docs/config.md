---
layout: default
title: Configuring IOStreams
description: >-
  Keeping paths in configuration so the same code targets different storage per
  environment, named roots via IOStreams.add_root, plus the temp directory, when
  temp files are used, and logger settings.
---

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
* Keep credentials in configuration too, for example the AWS environment variables or credential files for S3,
  and the ssh config for SFTP.

When an application uses several locations, [roots](#add_root) give them names, and each root can be set from
configuration:

~~~ruby
IOStreams.add_root(:default, ENV.fetch("FILES_ROOT"))
IOStreams.join("exports", "daily.csv").write(report)
~~~

## add_root

Roots allow paths to reference a particular root directory, so that all path names are appended to that root.
Their primary purpose is to allow the exact same code to run in production and development, yet use completely
different data sources in each. For example, in production a root can point to an S3 bucket, while in
development it points to the local file system.

Roots are configured via an initializer at startup. `IOStreams.join` then joins the supplied path
elements onto the named root, using the `:default` root whenever a root is not supplied.

Set the default root for this environment in an initializer:
~~~ruby
IOStreams.add_root(:default, "/var/my_app/files")
~~~

Now the default root path is available:
~~~ruby
IOStreams.root
# => #<IOStreams::Paths::File:/var/my_app/files pipeline={}>
 
IOStreams.root.to_s
# => "/var/my_app/files"
~~~

Comparing the final path using `path` and then `join` that uses a root path:
~~~ruby
IOStreams.path("/var/my_app/files", "my_test_file.txt").to_s
# => "/var/my_app/files/my_test_file.txt"

IOStreams.join("my_test_file.txt").to_s
# => "/var/my_app/files/my_test_file.txt"
~~~


Using `path`:
~~~ruby
IOStreams.path("/var/my_app/files", "my_test_file.txt").write("Hello World")
~~~

With the default root path configured the above code can be simplified by using `join` since it resolves to the same path.
~~~ruby
IOStreams.join("my_test_file.txt").write("Hello World")
~~~

Multiple roots can be setup, for example one for input files, another for output files, another for
reports, etc. During development the roots can all point to a common location, while in production
they could be completely different S3 buckets.

For example add special paths for `downloads` and `uploads`.
~~~ruby
IOStreams.add_root(:downloads, "/var/my_app/downloads")
IOStreams.add_root(:uploads, "/var/my_app/uploads")
~~~

An example that writes a file into the `/var/my_app/downloads` directory:
~~~ruby
IOStreams.join("my_test_file.txt", root: :downloads).write("Hello World")
~~~

The other benefit is that the root paths used in an application are externalized from the code base. That way the
roots can be changed to different locations depending on the environment.

We can also change the storage mechanism by changing the root:
~~~ruby
IOStreams.add_root(:downloads, "s3://my-app-bucket-name/downloads")
IOStreams.add_root(:uploads, "s3://my-app-bucket-name/uploads")
~~~

Now the application will write to S3 and the code does not change at all.
~~~ruby
IOStreams.join("my_test_file.txt", root: :downloads).write("Hello World")
~~~

To use or query a configured root path:
~~~ruby
IOStreams.root(:downloads).to_s
# => "s3://my-app-bucket-name/downloads"
~~~

## temp_dir

IOStreams reads and writes files of any size a block at a time, and most streams never touch the disk.
For some storage locations and formats IOStreams copies the data into a temp file under the covers, see
[When temp files are used](#when-temp-files-are-used). Each temp file holds a whole file, so when working with
large files the standard temp location can be too small, for example to download a large file from S3, or to
copy one from S3 to SFTP, which holds two temp files at once.

By default IOStreams looks up the location to store temp files in the following order:
* `ENV['TMPDIR']`
* `ENV['TMP']`
* `ENV['TEMP']`
* `Etc.systmpdir`
* `/tmp` (if it exists)
* Otherwise `.`

To explicity set the temp file location the following config option can be used:

~~~ruby
IOStreams.temp_dir = "/var/really_big_temp"
~~~

### When temp files are used

The application reads and writes a block at a time wherever the file is stored, but S3, SFTP and HTTP paths
transfer the whole file through a temp file:

| Path | Reading | Writing | Why |
| --- | --- | --- | --- |
| Local file | No temp file | No temp file | |
| AWS S3 | Downloads the object into a temp file before the block is called | Writes into a temp file, which is uploaded once the block completes | The AWS SDK pushes the data that it downloads, and pulls the data that it uploads, the opposite of how the application reads and writes |
| SFTP | Downloads the file into a temp file before the block is called | Writes into a temp file, which is uploaded once the block completes | The `sftp` program transfers local files, and only uploads a regular file |
| HTTP(S) | Downloads the file into a temp file before the block is called | Writes into a temp file, which is uploaded with a single PUT once the block completes | Net::HTTP pushes the data that it downloads, and downloading first closes the connection before the block runs. An upload needs its `Content-Length`, and is sent again after a `307` or `308` redirect |
| An IO supplied to `IOStreams.stream` | No temp file | No temp file | |

Most formats are read and written as the data passes through them. A format that only works on whole files
reads or writes a local file directly when it has one: a local path, a `File` supplied to `IOStreams.stream`, or
the temp file of an S3, SFTP or HTTP path. Otherwise its data is copied into a temp file first, for example when
reading the zip file within `data.csv.zip.pgp`, which comes from `gpg` as it decrypts the file, or a zip file
supplied in a `StringIO`.

| Format | Reading | Writing | Why |
| --- | --- | --- | --- |
| `.gz`, `.gzip`, `.bz2`, `.enc` | No temp file | No temp file | Streamed |
| `.zip` | No temp file for a local file, otherwise a temp file holding the zip file | No temp file | A zip file lists its contents at its end, so reading one needs the whole file. Writing streams the zip file |
| `.xlsx`, `.xlsm` | A temp file holding the rows as CSV, and when it is not a local file, a temp file holding the spreadsheet | Not supported | The `creek` gem reads a spreadsheet file, and returns its rows to a block, so they are converted into CSV for the application to read |
| `.pgp`, `.gpg` | No temp file. With `verify_first: true`, a temp file holding the decrypted data | No temp file | `gpg` reads and writes a local file itself, and any other stream through its stdin and stdout |

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
| `data.xlsx` | 1: the rows as CSV | Not supported |
| `data.csv.pgp`, read with `verify_first: true` | 1: the decrypted data | None |
| `data.csv.zip.pgp` | 1: the decrypted zip file | None |
| `s3://bucket/data.csv`, `s3://bucket/data.csv.pgp` | 1: the download | 1: the upload |
| `s3://bucket/data.xlsx` | 2: the download, and the rows as CSV | Not supported |
| `sftp://example.org/data.csv.zip.pgp` | 2: the download, and the decrypted zip file | 1: the upload |
| `IOStreams.stream(StringIO.new(data)).stream(:pgp)` | None | None |
| `IOStreams.stream(StringIO.new(data)).stream(:zip)` | 1: the zip file | None |

To see the temp files that IOStreams uses, set the [logger](#logger) to the debug level. Each temp file is logged
when it is created, with what it holds, and when it is deleted, with its size:

~~~
Created temp file /tmp/iostreams_s320261008-41-1x5yq2 for the download of s3://bucket/data.csv.zip.pgp
Created temp file /tmp/iostreams_reader20261008-41-9kq4ht for a copy of the input of IOStreams::Zip::Reader, which only reads files
Deleting temp file /tmp/iostreams_reader20261008-41-9kq4ht, which held 5242880 bytes
Deleting temp file /tmp/iostreams_s320261008-41-1x5yq2, which held 5251187 bytes
~~~

Notes:
* `#copy_from` and `#copy_to` read the source while they write the target, so copying from one S3, SFTP or HTTP
  path to another holds two temp files at once, each holding the whole file. S3 copies an object to another S3
  path itself, without a temp file, when copying with `convert: false`, or with `#move_to`, for an object smaller
  than 5GB.
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
optional second argument is the file extension.

## logger

IOStreams can log debug information, such as the external commands it runs for PGP and SFTP, and each temp
file that it uses, see [When temp files are used](#when-temp-files-are-used).

When [Semantic Logger](https://logger.reidmorrison.com) is loaded it is detected automatically, and IOStreams
logs to it without any additional configuration.

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

## enforce_column_restrictions

Applies `allowed_columns`, `required_columns` and `skip_unknown` to every input when reading
records, including JSON records, so that renaming an uploaded file from `.csv` to `.json` cannot
bypass them.

To return to the behavior before v3.0, where they only apply to a header row read from the file,
set it to false in an initializer. A warning is then logged when applying them would change the
records read:

~~~ruby
IOStreams.enforce_column_restrictions = false
~~~

Default: true. It defaulted to false before v3.0. See [Header options](formats#header-options).
