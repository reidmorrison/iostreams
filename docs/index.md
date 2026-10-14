---
layout: default
heading: What is IOStreams?
---

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

IOStreams reads the file name, `data.csv.gz`, infers that it is a gzip compressed CSV file, and builds the pipeline
of streams that reads it from S3, decompresses it, and parses it. Point the same code at `data.csv`, `data.csv.pgp`,
`data.xlsx` or a local file instead, and nothing else changes.

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

Read each record of a compressed CSV file on S3, as a Hash:

~~~ruby
IOStreams.path("s3://my-bucket/people.csv.gz").each(:hash) do |person|
  p person
  # => {"name" => "Jack", "born" => "1990-02-01"}
end
~~~

Describe the columns of the file with a [schema](formats#schema), so that each value is read as its type:

~~~ruby
people = IOStreams.path("s3://my-bucket/people.csv.gz").schema(
  fields: [{name: "name", type: "string"}, {name: "born", type: "date"}]
)
people.each(:hash) { |person| p person }
# => {"name" => "Jack", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>}
~~~

Convert it to JSON, compressed and encrypted, by copying it to a path whose name says so:

~~~ruby
target = IOStreams.path("exports/people.json.gz.pgp").option(:pgp, recipient: "partner@example.org")
target.copy_from(people, mode: :hash)
~~~

Write an Excel spreadsheet, or a Parquet file, from records:

~~~ruby
IOStreams.path("report.xlsx").writer(:hash) do |io|
  io << {"name" => "Jack", "total" => 12}
  io << {"name" => "Jill", "total" => 20}
end
~~~

Rescue a missing file the same way wherever it is stored:

~~~ruby
begin
  IOStreams.path(ENV.fetch("UPLOAD_PATH")).each(:hash) { |record| p record }
rescue IOStreams::Errors::NotFound => e
  puts "Nothing to process: #{e.message}"
end
~~~

## What IOStreams supports

| Storage | Url |
|---------|-----|
| Local files | `/data/file.csv`, `~/data/file.csv`, `file:///data/file.csv` |
| AWS S3, and S3 compatible stores | `s3://bucket/key` |
| SFTP | `sftp://host/path`, `sftp://host/~/path` within the login directory |
| HTTP and HTTPS | `https://host/path`, read with GET and written with PUT |

| Tabular format | Extension | Read | Write |
|----------------|-----------|------|-------|
| CSV | `.csv` | yes | yes |
| Pipe separated values | `.psv` | yes | yes |
| JSON Lines, one JSON object on each line | `.json` | yes | yes |
| Fixed width | `.fixed`, or `format(:fixed)` | yes | yes |
| Excel spreadsheet | `.xlsx`, `.xlsm` | yes | yes |
| Apache Parquet | `.parquet` | yes | yes |

| Compression and encryption | Extension |
|----------------------------|-----------|
| gzip | `.gz`, `.gzip` |
| bzip2 | `.bz2` |
| Zip | `.zip` |
| Zstandard | `.zst` |
| PGP, with GnuPG | `.pgp`, `.gpg` |
| [Symmetric Encryption](https://encryption.reidmorrison.com/) | `.enc` |

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
| The `number` fields of a schema | `bigdecimal`, a bundled gem from Ruby 3.4 |

When a gem is missing, the feature that needs it raises `LoadError`, naming the gem to install.

## Next steps

* The [tutorial](tutorial) walks through reading and writing files, step by step.
* [Paths](path) explains where files can be stored, and the operations on a path.
* [Reading and writing](streams) explains lines, rows, records and text encodings.
* [Tabular formats](formats) explains CSV, JSON, fixed width and Parquet files, and schemas.
* [Upgrading](upgrading) lists what changed in v3.0, and what to check when upgrading.
