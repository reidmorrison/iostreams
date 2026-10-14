---
layout: default
title: Tutorial
heading: File / Data Streaming with Ruby
description: >-
  A step by step introduction to streaming files with IOStreams, from writing a
  compressed file to reading typed records from S3.
---

When a file is small it can simply be read into memory. A file of many gigabytes cannot. On Linux, pipes stream the
data between programs instead, a block at a time:

~~~
# Count the lines in a file that was compressed with gzip
cat abc.gz | gunzip -c | wc -l
~~~

Ruby reads and writes files as streams, but has no built-in way to pass one stream through another, for example to
compress data, encrypt it, and then write the result to a file. IOStreams chains streams together like that, so that
only the current block of the file is in memory, whatever its size, and so that your code does not change when the
format, compression, encryption or location of the file does.

## Install

Install the gem:

~~~
gem install iostreams
~~~

To follow the S3 steps below, also install the AWS SDK, and configure its credentials as described in
[Configuring the AWS SDK for Ruby](https://docs.aws.amazon.com/sdk-for-ruby/v3/developer-guide/setup-config.html):

~~~
gem install aws-sdk-s3
~~~

Open an interactive Ruby console, and load IOStreams:

~~~ruby
require "iostreams"
~~~

## Write and read a file

A path names a file. Writing creates the file, and any directories that it is in:

~~~ruby
path = IOStreams.path("sample/hello.txt")
path.write("Hello World\n")

path.read
# => "Hello World\n"
~~~

To write a large file, write it a block at a time in a block, which closes the file when it returns:

~~~ruby
path.writer do |io|
  io << "Hello World\n"
  io << "Goodbye World\n"
end
~~~

## Compression by name

The extensions of the file name say how the file is stored. Name the file `.gz`, and it is compressed with gzip:

~~~ruby
path = IOStreams.path("sample/example.csv.gz")
# => #<IOStreams::Paths::File:sample/example.csv.gz pipeline={gz: {}}>

path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Reading the file decompresses it, as it is read:

~~~ruby
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

The `pipeline` above lists the streams that the file name implies. A file name can imply several, which are applied
in order, so `example.csv.gz.pgp` is encrypted with PGP after it is compressed with gzip, and decrypted before it is
decompressed:

| File name | Streams |
|-----------|---------|
| `hello.zip` | Compressed with Zip |
| `hello.gz.enc` | Compressed with gzip, then encrypted with Symmetric Encryption |
| `hello.csv.zst.pgp` | Compressed with Zstandard, then encrypted with PGP |

## Lines, rows and records

Rather than parse the file yourself, read it a line, a row or a record at a time:

~~~ruby
path.each do |line|
  puts line
end
~~~

Output:

~~~
name,login
Jack Jones,jjones
Jill Smith,jsmith
~~~

Pass `:array` to `each` to have IOStreams parse each line as CSV:

~~~ruby
path.each(:array) do |row|
  p row
end
~~~

Output:

~~~ruby
["name", "login"]
["Jack Jones", "jjones"]
["Jill Smith", "jsmith"]
~~~

And pass `:hash` to read each record as a Hash, keyed by the header row:

~~~ruby
path.each(:hash) do |record|
  p record
end
~~~

Output:

~~~ruby
{"name" => "Jack Jones", "login" => "jjones"}
{"name" => "Jill Smith", "login" => "jsmith"}
~~~

As the file grows to millions of rows, this code does not change, and its memory use stays about the same, since the
file is read, decompressed and parsed one block at a time.

## Writing records

Write records the same way, and IOStreams writes the header row and the CSV for you, quoting values as needed:

~~~ruby
path.writer(:hash) do |io|
  io << {name: "Jack Jones", login: "jjones"}
  io << {name: "Jill Smith", login: "jsmith"}
end

path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

The keys of the first record become the header row. Change the file name to `example.json`, and the same code writes
one JSON object on each line instead:

~~~ruby
IOStreams.path("sample/example.json").writer(:hash) do |io|
  io << {name: "Jack Jones", login: "jjones"}
  io << {name: "Jill Smith", login: "jsmith"}
end

IOStreams.path("sample/example.json").read
# => "{\"name\":\"Jack Jones\",\"login\":\"jjones\"}\n{\"name\":\"Jill Smith\",\"login\":\"jsmith\"}\n"
~~~

Name it `example.xlsx` to write an Excel spreadsheet, or `example.psv` for pipe separated values. Reading any of them
with `each(:hash)` returns the same records.

## Describe the file with a schema

Every value of a CSV file is text. A [schema](formats#schema) gives each column a name and a type, so that reading
returns each value as its type, and writing writes each value in the text form of its type:

~~~ruby
path = IOStreams.path("sample/people.csv").schema(
  fields: [
    {name: "name",   type: "string"},
    {name: "born",   type: "date"},
    {name: "salary", type: "number", decimals: 2}
  ]
)

path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "born" => Date.new(1990, 2, 1), "salary" => BigDecimal("1234.5")}
end

path.read
# => "name,born,salary\nJack Jones,1990-02-01,1234.50\n"

path.each(:hash) { |person| p person }
# => {"name" => "Jack Jones", "born" => #<Date: 1990-02-01>, "salary" => 0.12345e4}
~~~

A `number` field needs the `bigdecimal` gem, so `require "bigdecimal"` first.

The schema also checks the columns of the file, so that a file with other columns raises
`IOStreams::Errors::InvalidHeader`, rather than being read wrongly. A schema can accept extra columns, match columns
named another way, such as `First Name` for the field `first_name`, describe a file without a header row, and give
the position of each field of a fixed width file. See [Schema](formats#schema).

## Same code, any file type

Here is a method that writes a few lines to a file:

~~~ruby
def write_lines(path)
  IOStreams.path(path).writer do |io|
    io << "name,login\n"
    io << "Jack Jones,jjones\n"
    io << "Jill Smith,jsmith\n"
  end
end
~~~

And one that displays a file a line at a time, with the number of each line:

~~~ruby
def show_lines(path)
  line_number = 0
  IOStreams.path(path).each(:line) do |line|
    line_number += 1
    puts "[#{line_number}] #{line}"
  end
end
~~~

Use them with a plain file, a compressed file, and a file encrypted with PGP. A PGP file needs the recipient that can
decrypt it, so set its option on the path, and pass the path to the method:

~~~ruby
write_lines("sample/example.csv")
write_lines("sample/example.csv.gz")

encrypted = IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: "receiver@example.org")
write_lines(encrypted)

show_lines("sample/example.csv")
show_lines("sample/example.csv.gz")
show_lines(encrypted.option(:pgp, passphrase: "receiver_passphrase"))
~~~

`IOStreams.path` accepts a path as well as a name, and returns a copy of it with its streams and options, so the
methods do not need to know about PGP at all. Each file displays the same lines:

~~~
[1] name,login
[2] Jack Jones,jjones
[3] Jill Smith,jsmith
~~~

The PGP steps need GnuPG, and a key for `receiver@example.org`. See [PGP](pgp) to create one.

## Same code, any storage

The same unchanged methods read and write files on S3, by prefixing the names with the bucket:

~~~ruby
write_lines("s3://my-iostreams-bucket/sample/example.csv")
write_lines("s3://my-iostreams-bucket/sample/example.csv.gz")

show_lines("s3://my-iostreams-bucket/sample/example.csv")
show_lines("s3://my-iostreams-bucket/sample/example.csv.gz")
~~~

They also work with SFTP, `sftp://host/path`, and HTTP, `https://host/path`. S3 objects and HTTP files are read as
the code reads them, and S3 objects are uploaded as they are written, so a large file never has to fit in memory or on
local disk.

### Configure storage once, not in every call

The `s3://my-iostreams-bucket/` prefix in each call still makes the code decide where the files are stored. Instead,
keep the location in configuration, so that the same code runs against local files in development and S3 in
production. Roots make that possible. Set the location once, at startup:

~~~ruby
# config/initializers/iostreams.rb (development)
IOStreams.add_root(:default, "tmp/files")

# config/initializers/iostreams.rb (production)
IOStreams.add_root(:default, "s3://my-iostreams-bucket/files")
~~~

Then use `IOStreams.join` instead of `IOStreams.path`, and never mention the location again:

~~~ruby
write_lines(IOStreams.join("sample/example.csv"))
show_lines(IOStreams.join("sample/example.csv"))
~~~

A whole path can also come from configuration, such as `IOStreams.path(ENV.fetch("EXPORT_PATH"))`. See
[Configuration](config) for several roots, for example separate locations for uploads, downloads and reports.

## Files in another encoding

Lines, rows and records are read as UTF-8, and a file that is not valid UTF-8 raises
`IOStreams::Errors::InvalidEncoding`, which names the invalid byte, its offset, and its line. To read a file exported
in another encoding, such as Windows-1252, set its encoding on the path, here converting it to UTF-8:

~~~ruby
IOStreams.path("sample/legacy.csv").encoding("Windows-1252:UTF-8").each(:hash) do |record|
  p record
end
~~~

See [Text and binary data](streams#text-and-binary-data).

## When a file is missing

Each store raises its own error for a missing file, such as `Errno::ENOENT` for a local file. IOStreams also tags it
with `IOStreams::Errors::NotFound`, so that the same rescue works wherever the file is stored:

~~~ruby
begin
  show_lines(IOStreams.join("sample/missing.csv"))
rescue IOStreams::Errors::NotFound => e
  puts "Not found: #{e.message}"
end
~~~

See [Errors](errors) for the other kinds of failure.

## Copy and convert

`copy_from` copies a file, applying the streams of both names, so this copy decompresses the source and encrypts the
target:

~~~ruby
target = IOStreams.path("sample/example.csv.pgp").option(:pgp, recipient: "receiver@example.org")
target.copy_from("sample/example.csv.gz")
~~~

With a mode, it converts the format of each record too, here from CSV to JSON:

~~~ruby
IOStreams.path("sample/people.json").copy_from("sample/example.csv.gz", mode: :hash)
~~~

See [Copying and moving](copy_files).

## Files that must be on local disk

A few formats can only be read from a local file, since they are not read from start to end. A zip file lists its
contents at its end, so reading one from S3 or a web server first copies it into a temp file, for example:

~~~ruby
IOStreams.path("https://example.com/files/offices.zip").
  option(:zip, entry_file_name: "OFFICES.CSV").
  each(:hash) do |office|
    p office
    break
  end
~~~

Gzip and Zstandard compressed files are read without a temp file, so prefer them for large files. See
[When temp files are used](config#when-temp-files-are-used).

## Next steps

* [Paths](path): local files, S3, SFTP and HTTP, and the operations on a path.
* [Reading and writing](streams): every way to read and write a path.
* [Tabular formats](formats): CSV, JSON, fixed width, Excel and Parquet, and schemas.
* [PGP](pgp): encrypting, decrypting and signing files with PGP.
