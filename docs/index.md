---
layout: default
heading: What is IOStreams?
---

**Contents**

* TOC
{:toc}

IOStreams is a streaming library for Ruby that makes the format, compression, encryption and storage location of a
file transparent to your code. Read and write files of any size, one block at a time, whether they are CSV, JSON,
Excel or Parquet, compressed with gzip, zip, bzip2 or Zstandard, encrypted with PGP, and whether they are stored on
local disk, AWS S3, an SFTP server, or a web server.

## Why IOStreams?

Processing files in Ruby usually means writing different code for every variation. One customer sends a gzip
compressed CSV file, another a PGP encrypted file, a third uploads an Excel spreadsheet. The files are on local disk in
development, but in AWS S3 in production. Each combination needs its own handling, and reading a large file into
memory all at once risks exhausting it.

Consider reading a gzip compressed CSV file from S3, one record at a time, _without_ IOStreams:

~~~ruby
require "aws-sdk-s3"
require "zlib"
require "csv"

response = Aws::S3::Client.new.get_object(bucket: "my-bucket", key: "data.csv.gz")
gz       = Zlib::GzipReader.new(response.body)
headers  = nil
gz.each_line do |line|
  row = CSV.parse_line(line)
  if headers.nil?
    headers = row
  else
    record = headers.zip(row).to_h
    # ... process record ...
  end
end
~~~

Change that file to plain CSV, to a PGP encrypted file, or move it back to local disk, and this code has to change
every time. It also downloads the whole object before the first record is processed. With IOStreams the same code
handles all of them, while it streams the file:

~~~ruby
IOStreams.path("s3://my-bucket/data.csv.gz").each(:hash) do |record|
  # ... process record ...
end
~~~

IOStreams reads the file name, `data.csv.gz`, infers that it is a gzip compressed CSV file, and builds the
[pipeline of streams](#how-it-works) that reads it from S3, decompresses it, and parses it. Point the same code at
`data.csv`, `data.xlsx`, a local file, or `data.csv.pgp` with its passphrase set on the path, and nothing else
changes.

### One API, whatever the format, compression or encryption

IOStreams detects the streams of a file from the extensions of its name and applies them in order, so
`sample.csv.gz.pgp` is decrypted, then decompressed, then parsed as CSV, without a line of special handling. The same
code that reads a plain CSV file also reads an Excel spreadsheet, a PGP encrypted JSON file, or a Parquet file. A
single background job can process files from many senders, in many formats, with no code for each format.

### One API, wherever the file is stored

Local disk, AWS S3, S3 compatible stores, SFTP and HTTP(S) share the same `IOStreams.path` interface, and the
same operations, such as `#each_child`, `#exist?`, `#delete` and `#move_to`, behave the same way on each of them.

### Constant memory, even for huge files

Everything is read and written a block at a time, so a 10 GB compressed file uses about as much memory as a 10 KB
one, and the code that processes ten rows processes ten million without changes. Files on S3 and HTTP are read as
your code reads them, and S3 objects are uploaded as they are written, without a copy on local disk.

### Paths are configuration, not code

A path or url can come from an environment variable or a configuration system, so the exact same application code
runs against local files in development and S3 or SFTP in production. With [roots](config#add_root), the storage
location is set once, at startup. See [Paths are configuration](config#paths-are-configuration).

## A quick tour

Write a CSV file, compressed with gzip, a record at a time:

~~~ruby
IOStreams.path("people.csv.gz").writer(:hash) do |io|
  io << {"name" => "Jack", "born" => "1990-02-01"}
  io << {"name" => "Jill", "born" => "1992-07-14"}
end
~~~

Read it back a record at a time, as a Hash, while it is decompressed:

~~~ruby
IOStreams.path("people.csv.gz").each(:hash) do |person|
  p person
end
# {"name" => "Jack", "born" => "1990-02-01"}
# {"name" => "Jill", "born" => "1992-07-14"}
~~~

The same code reads `s3://my-bucket/people.csv.gz` or `sftp://sftp.example.org/people.csv.gz` instead: only the name
changes. See [Paths](path) for the gems and credentials of each store.

Describe the columns of the file with a [schema](formats#schema), so that each value is read as its type:

~~~ruby
people = IOStreams.path("people.csv.gz").schema(
  fields: [
    {name: "name", type: "string"},
    {name: "born", type: "date"}
  ]
)
people.each(:hash) do |person|
  p person
end
# {"name" => "Jack", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>}
# {"name" => "Jill", "born" => #<Date: 1992-07-14 ((2448818j,0s,0n),+0s,2299161j)>}
~~~

Convert it to another format by copying it to a path whose name says so:

~~~ruby
IOStreams.path("people.json").copy_from(people, mode: :hash)

IOStreams.path("people.json").read
# => "{\"name\":\"Jack\",\"born\":\"1990-02-01\"}\n{\"name\":\"Jill\",\"born\":\"1992-07-14\"}\n"
~~~

The target can be anywhere, compressed and encrypted, such as JSON on S3, encrypted with PGP for a partner whose public
key is in your keyring, see [PGP](pgp):

~~~ruby
IOStreams.path("s3://my-bucket/exports/people.json.gz.pgp").
  option(:pgp, recipient: "partner@example.org").
  copy_from(people, mode: :hash)
~~~

Write an Excel spreadsheet from records. A Parquet file is written the same way, with a schema that gives the type of
each column, see [Parquet files](formats#parquet-files):

~~~ruby
IOStreams.path("report.xlsx").writer(:hash) do |io|
  io << {"name" => "Jack", "total" => 12}
  io << {"name" => "Jill", "total" => 20}
end
~~~

Rescue a missing file the same way wherever it is stored, so that the path can come from configuration:

~~~ruby
begin
  IOStreams.path("missing.csv").each(:hash) do |record|
    p record
  end
rescue IOStreams::Errors::NotFound => e
  puts "Nothing to process: #{e.message}"
end
# Nothing to process: No such file or directory @ rb_sysopen - missing.csv
~~~

## How it works

* A **path** names a file and the store that holds it, such as `IOStreams.path("s3://my-bucket/people.csv.gz")`.
  `IOStreams.stream(io)` reads or writes an IO that you already have, such as a `StringIO`, the same way. See
  [Paths](path).
* Each extension at the end of the file name, such as `.gz` or `.pgp`, names a **stream** that the data passes
  through, a block at a time. In order, they are the **pipeline** of the path: reading `people.csv.gz.pgp` decrypts the
  data and then decompresses it, and writing it compresses the data and then encrypts it. See
  [Streams from the file name](streams#streams-from-the-file-name).
* The **tabular format** of the file, such as `.csv`, `.json` or `.xlsx`, says how its rows and records are stored.
  See [Tabular formats](formats).
* The **mode** says what your code reads or writes: blocks of bytes (`:stream`), lines of text (`:line`), **rows**,
  each an Array of the values of a line (`:array`), or **records**, each a Hash of those values by column name
  (`:hash`). For a CSV file, the names of the columns come from its **header row**, its first line. See
  [Reading and writing](streams).
* A **schema** names the columns of a file, gives the type of each one, such as a `Date`, and says which columns a
  file can have. See [Schema](formats#schema).

## Common tasks

**Read a CSV, JSON or Excel file a record at a time**, see [Reading](streams#reading):

~~~ruby
IOStreams.path("people.csv").each(:hash) do |record|
  p record
end
~~~

**Write a file compressed with gzip**, see [gzip](extensions#gzip):

~~~ruby
IOStreams.path("people.csv.gz").writer(:hash) do |io|
  io << {name: "Jack", born: "1990-02-14"}
end
~~~

**Convert CSV to JSON**, see [Converting rows and records](copy_files#converting-rows-and-records):

~~~ruby
IOStreams.path("people.json").copy_from("people.csv", mode: :hash)
~~~

**Export a database query to CSV, keeping the types of its columns**, see [Exporting queries](queries):

~~~ruby
IOStreams.path("orders.csv").copy_from(Order.where(paid: true), mode: :hash)
~~~

**Upload a file to S3**, see [Copying and moving](copy_files):

~~~ruby
IOStreams.path("s3://my-bucket/people.csv").copy_from("people.csv")
~~~

**Encrypt a file with PGP**, see [PGP](pgp):

~~~ruby
IOStreams.path("people.csv.pgp").
  option(:pgp, recipient: "partner@example.org").
  copy_from("people.csv")
~~~

**Decrypt a PGP file**, see [PGP](pgp):

~~~ruby
IOStreams.path("people.csv.pgp").
  option(:pgp, passphrase: ENV.fetch("PGP_PASSPHRASE")).
  read
~~~

**Read numbers and dates as their types, and skip the other columns**, see [Schema](formats#schema):

~~~ruby
IOStreams.path("people.csv").
  schema(fieldsMatch: "partial", fields: [{name: "born", type: "date"}]).
  each(:hash) do |record|
    p record
  end
~~~

**Read a Windows-1252 file as UTF-8**, see [Character encoding](streams#character-encoding):

~~~ruby
IOStreams.path("people.csv").encoding("Windows-1252:UTF-8").each(:hash) do |record|
  p record
end
~~~

**Process a large file in background jobs**, a slice of 500 rows in each job, see [Background jobs](background_jobs):

~~~ruby
IOStreams.path("s3://my-bucket/people.csv.gz").each(:slice, size: 500) do |slice|
  ImportPeopleJob.perform_later(slice.to_h)
end
~~~

**List the CSV files in a directory or bucket**, see [Listing files](path#listing-files):

~~~ruby
IOStreams.path("s3://my-bucket/inbound").each_child("*.csv") do |path|
  p path
end
~~~

**Keep the location of the files in configuration**, see [Configuration](config#add_root):

~~~ruby
# At startup
IOStreams.add_root(:default, ENV.fetch("FILES_ROOT"))

# Then anywhere in the application
IOStreams.join("people.csv").each(:hash) do |record|
  p record
end
~~~

**Handle a missing file wherever it is stored**, see [Errors](errors):

~~~ruby
begin
  IOStreams.path("s3://my-bucket/people.csv").read
rescue IOStreams::Errors::NotFound
  puts "people.csv has not arrived yet"
end
~~~

**Keep untrusted file names within a directory**, see [Security](security#allowed-paths):

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
~~~

## What IOStreams supports

| Storage | Url |
|---------|-----|
| [Local files](path#file) | `/data/file.csv`, `~/data/file.csv`, `file:///data/file.csv` |
| [AWS S3](path#aws-s3-s3), and S3 compatible stores | `s3://bucket/key` |
| [SFTP](path#sftp-sftp) | `sftp://host/path`, `sftp://host/~/path` within the login directory |
| [HTTP and HTTPS](path#http-http-https) | `https://host/path`, read with GET and written with PUT |

| Tabular format | Extension | Read | Write |
|----------------|-----------|------|-------|
| [CSV](formats#csv-and-psv-files) | `.csv` | yes | yes |
| [Pipe separated values](formats#csv-and-psv-files) | `.psv` | yes | yes |
| [JSON Lines](formats#json-files), one JSON object on each line | `.json` | yes | yes |
| [Fixed width](formats#fixed-width-files) | `.fixed`, or `format(:fixed)` | yes | yes |
| [Excel spreadsheet](formats#excel-spreadsheets) | `.xlsx`, `.xlsm` | yes | yes |
| [Apache Parquet](formats#parquet-files) | `.parquet` | yes | yes |
| [Lines of text](formats#lines-of-text), such as one email address on each line | `.lines`, or `format(:lines)` | yes | yes |

| Compression and encryption | Extension |
|----------------------------|-----------|
| [gzip](extensions#gzip) | `.gz`, `.gzip` |
| [bzip2](extensions#bzip2) | `.bz2` |
| [Zip](extensions#zip) | `.zip` |
| [Zstandard](extensions#zstandard) | `.zst` |
| [PGP](pgp), with GnuPG | `.pgp`, `.gpg` |
| [Symmetric Encryption](extensions#symmetric-encryption) | `.enc` |

## Installation

Add the gem to your Gemfile, for Ruby 3.3 or later:

~~~ruby
gem "iostreams"
~~~

IOStreams itself needs no other gems. Each feature that needs one loads it when it is first used, so add only the
gems of the features that your application uses:

| Feature | Gems and programs |
|---------|-------------------|
| AWS S3 | `aws-sdk-s3` |
| SFTP | The `sftp` program of OpenSSH, and `sshpass` to log in with a password. `net-sftp` to list, check and delete files, with `ed25519` and `bcrypt_pbkdf` for ed25519 keys |
| bzip2 | `bzip2-ffi` |
| Zip | `rubyzip` to read, `zip_kit` to write |
| Zstandard | `zstd-ruby`, or on JRuby the zstd-jni jar, see [Compression and encryption](extensions#zstandard) |
| Excel spreadsheets | `creek` to read, `xlsxtream` to write |
| PGP | The `gpg` program of GnuPG 2.1 or later, see [PGP](pgp#installation) |
| Symmetric Encryption | `symmetric-encryption` |
| Parquet | `parquet`, which is not available on JRuby |
| [Active Record queries](queries) | `activerecord` 7.2 or later, and the driver of the database: `pg`, `mysql2` or `sqlite3` |
| The `number` fields of a schema | `bigdecimal`, a bundled gem from Ruby 3.4 |

When a gem is missing, the feature that needs it raises `LoadError`, naming the gem to install.

## Next steps

* The [tutorial](tutorial) walks through reading and writing files, step by step.
* [Reading and writing](streams): lines, rows, records and text encodings.
* [Tabular formats](formats): CSV, JSON, Excel, fixed width and Parquet files, and schemas.
* [Compression and encryption](extensions): gzip, zip, bzip2, Zstandard, PGP and Symmetric Encryption.
* [Paths](path): local files, S3, SFTP and HTTP, and the operations on a path.
* [Copying and moving](copy_files): copying files between stores, and converting them on the way.
* [Exporting queries](queries): exporting the rows of an Active Record query to any format and store.
* [Background jobs](background_jobs): processing a large file or query in background jobs, in parallel, or in one job that
  resumes where it stopped.
* [Errors](errors): rescuing a missing file the same way wherever it is stored.
* [PGP](pgp): encrypting, decrypting, signing and verifying files, and managing keys.
* [Configuration](config): roots, temp files and logging.
* [Security](security): allowed paths, untrusted urls and credentials.
* [Upgrading](upgrading): what changed in v3.0, for applications that use an earlier version.
