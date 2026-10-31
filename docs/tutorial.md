---
layout: default
title: Tutorial
heading: File / Data Streaming with Ruby
description: >-
  A step by step introduction to streaming files with IOStreams, from writing a
  compressed file to reading typed records from S3.
---

**Contents**

* TOC
{:toc}

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

In an application, add `gem "iostreams"` to its Gemfile instead, with the gems of the features that it uses, see
[Installation](index.html#installation).

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

`:line`, `:array` and `:hash` are the **modes** of `#each`, which say what your code reads: a line is a String, a
**row** an Array of the values of a line, and a **record** a Hash of those values, keyed by the names in the header
row. `#writer` takes the same modes. See [Reading and writing](streams).

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

## Typed records with a contract

Every value of a CSV file is text. A [contract](contracts) names the fields that your code needs, and the type of
each one, so that reading returns each value as its type, and writing writes each value in the text form of its type.
Declare it as a class, with a field for each value:

~~~ruby
class Person < IOStreams::Contract
  field :name,   :string
  field :born,   :date
  field :salary, :number, decimals: 2
end
~~~

Set the contract on the path with `#as`, and write a record:

~~~ruby
path = IOStreams.path("sample/people.csv").as(Person)

path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "born" => Date.new(1990, 2, 1), "salary" => BigDecimal("1234.5")}
end

path.read
# => "name,born,salary\nJack Jones,1990-02-01,1234.50\n"
~~~

Read each record as a `Person`, whose methods return the values of its fields as their types:

~~~ruby
path.each(:record) do |person|
  puts "#{person.name} was born in #{person.born.year}"
end
# Jack Jones was born in 1990
~~~

Or read each one as a Hash of the same values:

~~~ruby
path.each(:hash) do |person|
  p person
end
# => {"name" => "Jack Jones", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>, "salary" => 0.12345e4}
~~~

The contract also checks the file: one without a column that the contract needs raises
`IOStreams::Errors::InvalidHeader` before the first record, rather than being read wrongly, and a value that is not of
the type of its field, such as `N/A` for `salary`, raises `IOStreams::Errors::InvalidValue`, naming the field, the
value and its line. A contract can accept extra columns, match columns named another way, such as `First Name` for the
field `first_name`, and report every invalid row of an upload rather than stop at the first. See
[Contracts](contracts).

### Draft a contract from a file

For a file that you already have, let IOStreams draft the contract from a sample of its values, then review the class
that it writes, and save it with your code:

~~~ruby
puts IOStreams.path("sample/people.csv").infer_schema(sample: 100).to_dsl("Person")
# class Person < IOStreams::Contract
#   fields_match "subset"
#
#   field :name,   :string
#   field :born,   :date
#   field :salary, :number, decimals: 2
# end
~~~

`fields_match "subset"` accepts a file with more columns than the contract lists. IOStreams never guesses types while
it reads, since a guess could change from one file to the next, so the draft is only a start, for you to review. See
[Drafting a contract](contracts#drafting-a-contract).

## Same records, any format

Each format reads values as it stores them. Copy the file to JSON and to a spreadsheet, and read each one back as a
Hash. The spreadsheet needs the `creek` and `xlsxtream` gems; without them, leave it out.

~~~ruby
IOStreams.path("sample/people.json").copy_from(path, mode: :hash)
IOStreams.path("sample/people.xlsx").copy_from(path, mode: :hash)

["sample/people.csv", "sample/people.json", "sample/people.xlsx"].each do |name|
  IOStreams.path(name).each(:hash) do |record|
    p record
  end
end
# {"name" => "Jack Jones", "born" => "1990-02-01", "salary" => "1234.50"}
# {"name" => "Jack Jones", "born" => "1990-02-01", "salary" => 1234.5}
# {"name" => "Jack Jones", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>, "salary" => 1234.5}
~~~

CSV holds text, JSON numbers but no dates, and the spreadsheet a date and a `Float`. Read through the contract, every
one of them yields the same record:

~~~ruby
["sample/people.csv", "sample/people.json", "sample/people.xlsx"].each do |name|
  IOStreams.path(name).as(Person).each(:hash) do |record|
    p record
  end
end
# {"name" => "Jack Jones", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>, "salary" => 0.12345e4}
# {"name" => "Jack Jones", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>, "salary" => 0.12345e4}
# {"name" => "Jack Jones", "born" => #<Date: 1990-02-01 ((2447924j,0s,0n),+0s,2299161j)>, "salary" => 0.12345e4}
~~~

So the code that processes the records does not change when a partner sends a spreadsheet instead of a CSV file, or
the file moves to Parquet, or the records come from a database query.

A CSV file with a header row, JSON, a spreadsheet and Parquet name their own columns. A file that cannot describe
itself, such as a fixed width file, or a CSV file without a header row, also needs a [schema](schemas), which
gives the name and position of each of its columns, and is usually held in configuration, beside its path. The
contract then meets the fields of the schema by their names, see
[A source that cannot describe itself](contracts#a-source-that-cannot-describe-itself).

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
decrypt it, so set its option on the path, and pass the path to the method. The PGP lines need GnuPG and a key for
`receiver@example.org`, which [Create the keys](pgp#create-the-keys) in the PGP tutorial creates. Without them, skip
the PGP lines.

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
local disk. A zip file or a spreadsheet is the exception: one stored elsewhere is copied into a temp file first, since
it is read from a local file, so prefer gzip or Zstandard for large files, see
[When temp files are used](config#when-temp-files-are-used).

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

## Next steps

* [Reading and writing](streams): every way to read and write a path, and text encodings.
* [File formats](formats): CSV, JSON, fixed width, Excel and Parquet.
* [Contracts](contracts): the typed records that your code needs, read the same way from any source.
* [Schemas](schemas): describing the columns of a file, and the types and properties of fields.
* [Compression and encryption](extensions): the options of each stream.
* [Paths](path): local files, S3, SFTP and HTTP, and the operations on a path.
* [Copying and moving](copy_files): copying files between stores, and converting them on the way.
* [Errors](errors): rescuing failures the same way wherever a file is stored.
* [PGP](pgp): encrypting, decrypting and signing files with PGP, and managing keys.
* [Configuration](config) and [Security](security): roots, temp files, logging and allowed paths.
