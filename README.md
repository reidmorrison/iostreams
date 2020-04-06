# iostreams
[![Gem Version](https://img.shields.io/gem/v/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Build Status](https://travis-ci.org/rocketjob/iostreams.svg?branch=master)](https://travis-ci.org/rocketjob/iostreams) [![Downloads](https://img.shields.io/gem/dt/iostreams.svg)](https://rubygems.org/gems/iostreams) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Production%20Ready-blue.svg) [![Gitter chat](https://img.shields.io/badge/IRC%20(gitter)-Support-brightgreen.svg)](https://gitter.im/rocketjob/support)

Input and Output streaming for Ruby.

## Project Status

Production Ready, but API is subject to breaking changes until V1 is released.

## Features

Supported streams:

* Zip
* Gzip
* BZip2
* PGP (Requires GnuPG)
* Xlsx (Reading)
* Encryption using [Symmetric Encryption](https://github.com/reidmorrison/symmetric-encryption)

Supported sources and/or targets:

* File
* HTTP (Read only)
* AWS S3
* SFTP

Supported file formats:

* CSV
* Fixed width formats
* JSON
* PSV

## Quick examples

Read an entire file into memory:

```ruby
IOStreams.path('example.txt').read
```

Decompress an entire gzip file into memory:

```ruby
IOStreams.path('example.gz').read
```

Read and decompress the first file in a zip file into memory:

```ruby
IOStreams.path('example.zip').read
```

Read a file one line at a time

```ruby
IOStreams.path('example.txt').each do |line|
  puts line
end
```

Read a CSV file one line at a time, returning each line as an array:

```ruby
IOStreams.path('example.csv').each(:array) do |array|
  p array
end
```

Read a CSV file a record at a time, returning each line as a hash. 
The first line of the file is assumed to be the header line:

```ruby
IOStreams.path('example.csv').each(:hash) do |hash|
  p hash
end
```

Read a file using an http get, 
decompressing the named file in the zip file,
returning each records from the named file as a hash:

```ruby
IOStreams.
  path("https://www5.fdic.gov/idasp/Offices2.zip").
  option(:zip, entry_file_name: 'OFFICES2_ALL.CSV').
  reader(:hash) do |stream|
    p stream.read
  end
```

Read the file without unzipping and streaming the first file in the zip:

```ruby
IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').stream(:none).reader {|file| puts file.read}
```


## Introduction

If all files were small, they could just be loaded into memory in their entirety. With the
advent of very large files, often into several Gigabytes, or even Terabytes in size, loading
them into memory is not feasible.
 
In linux it is common to use pipes to stream data between processes. 
For example:

```
# Count the number of lines in a file that has been compressed with gzip
cat abc.gz | gunzip -c | wc -l
```

For large files it is critical to be able to read and write these files as streams. Ruby has support
for reading and writing files using streams, but has no built-in way of passing one stream through
another to support for example compressing the data, encrypting it and then finally writing the result
to a file. Several streaming implementations exist for languages such as `C++` and `Java` to chain
together several streams, `iostreams` attempts to offer similar features for Ruby.

```ruby
# Read a compressed file:
IOStreams.path("hello.gz").reader do |reader|
  data = reader.read(1024)
  puts "Read: #{data}"
end
```

The true power of streams is shown when many streams are chained together to achieve the end
result, without holding the entire file in memory, or ideally without needing to create
any temporary files to process the stream.

```ruby
# Create a file that is compressed with GZip and then encrypted with Symmetric Encryption:
IOStreams.path("hello.gz.enc").writer do |writer|
  writer.write("Hello World")
  writer.write("and some more")
end
```

The power of the above example applies when the data being written starts to exceed hundreds of megabytes,
or even gigabytes.

By looking at the file name supplied above, `iostreams` is able to determine which streams to apply
to the data being read or written. For example:
* `hello.zip` => Compressed using Zip
* `hello.zip.enc` => Compressed using Zip and then encrypted using Symmetric Encryption
* `hello.gz.enc` => Compressed using GZip and then encrypted using Symmetric Encryption

The objective is that all of these streaming processes are performed used streaming
so that only the current portion of the file is loaded into memory as it moves
through the entire file.
Where possible each stream never goes to disk, which for example could expose
un-encrypted data.

## Examples

While decompressing the file, display 128 characters at a time from the file.

~~~ruby
require "iostreams"
IOStreams.path("abc.csv").reader do |io|
  while (data = io.read(128))
    p data 
  end
end
~~~

While decompressing the file, display one line at a time from the file.

~~~ruby
IOStreams.path("abc.csv").each do |line|
  puts line
end
~~~

While decompressing the file, display each row from the csv file as an array.

~~~ruby
IOStreams.path("abc.csv").each(:array) do |array|
  p array
end
~~~

While decompressing the file, display each record from the csv file as a hash.
The first line is assumed to be the header row.

~~~ruby
IOStreams.path("abc.csv").each(:hash) do |hash|
  p hash
end
~~~

Write data while compressing the file.

~~~ruby
IOStreams.path("abc.csv").writer do |io|
  io.write("This")
  io.write(" is ")
  io.write(" one line\n")
end
~~~

Write a line at a time while compressing the file.

~~~ruby
IOStreams.path("abc.csv").writer(:line) do |file|
  file << "these"
  file << "are"
  file << "all"
  file << "separate"
  file << "lines"
end
~~~

Write an array (row) at a time while compressing the file.
Each array is converted to csv before being compressed with zip.

~~~ruby
IOStreams.path("abc.csv").writer(:array) do |io|
  io << %w[name address zip_code]
  io << %w[Jack There 1234]
  io << ["Joe", "Over There somewhere", 1234]
end
~~~

Write a hash (record) at a time while compressing the file.
Each hash is converted to csv before being compressed with zip.
The header row is extracted from the first hash supplied.

~~~ruby
IOStreams.path("abc.csv").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {name: "Joe", address: "Over There somewhere", zip_code: 1234}
end
~~~

Write to a string IO for testing, supplying the filename so that the streams can be determined.

~~~ruby
io = StringIO.new
IOStreams.stream(io, file_name: "abc.csv").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {name: "Joe", address: "Over There somewhere", zip_code: 1234}
end
puts io.string
~~~

Read a CSV file and write the output to an encrypted file in JSON format.

~~~ruby
IOStreams.path("sample.json.enc").writer(:hash) do |output|
  IOStreams.path("sample.csv").each(:hash) do |record|
    output << record
  end
end
~~~

## Copying between files

Stream based file copying. Changes the file type without changing the file format. For example, compress or encrypt. 

Encrypt the contents of the file `sample.json` and write to `sample.json.enc`

~~~ruby
input = IOStreams.path("sample.json")
IOStreams.path("sample.json.enc").copy_from(input)
~~~

Encrypt and compress the contents of the file `sample.json` with Symmetric Encryption and write to `sample.json.enc`

~~~ruby
input = IOStreams.path("sample.json")
IOStreams.path("sample.json.enc").option(:enc, compress: true).copy_from(input)
~~~

Encrypt and compress the contents of the file `sample.json` with pgp and write to `sample.json.enc`

~~~ruby
input = IOStreams.path("sample.json")
IOStreams.path("sample.json.pgp").option(:pgp, recipient: "sender@example.org").copy_from(input)
~~~

Decrypt the file `abc.csv.enc` and write it to `xyz.csv`.

~~~ruby
input = IOStreams.path("abc.csv.enc")
IOStreams.path("xyz.csv").copy_from(input)
~~~

Decrypt file `ABC` that was encrypted with Symmetric Encryption, 
PGP encrypt the output file and write it to `xyz.csv.pgp` using the pgp key that was imported for `a@a.com`.

~~~ruby
input = IOStreams.path("ABC").stream(:enc)
IOStreams.path("xyz.csv.pgp").option(:pgp, recipient: "a@a.com").copy_from(input)
~~~

To copy a file _without_ performing any conversions (ignore file extensions), set `convert` to `false`:

~~~ruby
input = IOStreams.path("sample.json.zip")
IOStreams.path("sample.copy").copy_from(input, convert: false)
~~~

## Philosopy

IOStreams can be used to work against a single stream. it's real capability becomes apparent when chaining together
multiple streams to process data, without loading entire files into memory.

#### Linux Pipes

Linux has built-in support for streaming using the `|` (pipe operator) to send the output from one process to another. 

Example: count the number of lines in a compressed file: 

    gunzip -c hello.csv.gz | wc -l

The file `hello.csv.gz` is uncompressed and returned to standard output, which in turn is piped into the standard
input for `wc -l`, which counts the number of lines in the uncompressed data.

As each block of data is returned from `gunzip` it is immediately passed into `wc` so that it 
can start counting lines of uncompressed data, without waiting until the entire file is decompressed. 
The uncompressed contents of the file are not written to disk before passing to `wc -l` and the file is not loaded
into memory before passing to `wc -l`.

In this way extremely large files can be processed with very little memory being used.

#### Push Model

In the Linux pipes example above this would be considered a "push model" where each task in the list pushes
its output to the input of the next task.

A major challenge or disadvantage with the push model is that buffering would need to occur between tasks since 
each task could complete at very different speeds. To prevent large memory usage the standard output from a previous
task would have to be blocked to try and make it slow down.

#### Pull Model

Another approach with multiple tasks that need to process a single stream, is to move to a "pull model" where the
task at the end of the list pulls a block from a previous task when it is ready to process it.

#### IOStreams

IOStreams uses the pull model when reading data, where each stream performs a read against the previous stream 
when it is ready for more data.

When writing to an output stream, IOStreams uses the push model, where each block of data that is ready to be written
is pushed to the task/stream in the list. The write push only returns once it has traversed all the way down to
the final task / stream in the list, this avoids complex buffering issues between each task / stream in the list.

Example: Implementing in Ruby: `gunzip -c hello.csv.gz | wc -l`

~~~ruby
  line_count = 0
  IOStreams::Gzip::Reader.open("hello.csv.gz") do |input|
    IOStreams::Line::Reader.open(input) do |lines|
      lines.each { line_count += 1}
    end
  end
  puts "hello.csv.gz contains #{line_count} lines"
~~~

Since IOStreams can autodetect file types based on the file extension, `IOStreams.reader` can figure which stream
to start with:
~~~ruby
  line_count = 0
  IOStreams.path("hello.csv.gz").reader do |input|
    IOStreams::Line::Reader.open(input) do |lines|
      lines.each { line_count += 1}
    end
  end
  puts "hello.csv.gz contains #{line_count} lines"
~~~

Since we know we want a line reader, it can be simplified using `#reader(:line)`:
~~~ruby
  line_count = 0
  IOStreams.path("hello.csv.gz").reader(:line) do |lines|
    lines.each { line_count += 1}
  end
  puts "hello.csv.gz contains #{line_count} lines"
~~~

It can be simplified even further using `#each`:
~~~ruby
  line_count = 0
  IOStreams.path("hello.csv.gz").each { line_count += 1}
  puts "hello.csv.gz contains #{line_count} lines"
~~~

The benefit in all of the above cases is that the file can be any arbitrary size and only one block of the file
is held in memory at any time.

#### Chaining

In the above example only 2 streams were used. Streams can be nested as deep as necessary to process data.

Example, search for all occurrences of the word apple, cleansing the input data stream of non printable characters 
and converting to valid US ASCII.

~~~ruby
  apple_count = 0
  IOStreams::Gzip::Reader.open("hello.csv.gz") do |input|
    IOStreams::Encode::Reader.open(input, 
                                   encoding:       "US-ASCII", 
                                   encode_replace: "", 
                                   encode_cleaner: :printable) do |cleansed|
      IOStreams::Line::Reader.open(cleansed) do |lines|
        lines.each { |line| apple_count += line.scan("apple").count}
      end
  end
  puts "Found the word 'apple' #{apple_count} times in hello.csv.gz"
~~~

Let IOStreams perform the above stream chaining automatically under the covers:

~~~ruby
  apple_count = 0
  IOStreams.path("hello.csv.gz").
    option(:encode, encoding: "US-ASCII", replace: "", cleaner: :printable).
    each do |line|
      apple_count += line.scan("apple").count
    end

  puts "Found the word 'apple' #{apple_count} times in hello.csv.gz"
~~~

## Notes

* Due to the nature of Zip, both its Reader and Writer methods will create
  a temp file when reading from or writing to a stream.
  Recommended to use Gzip over Zip since it can be streamed without requiring temp files.
* Zip becomes exponentially slower with very large files, especially files
  that exceed 4GB when uncompressed. Highly recommend using GZip for large files.

## Versioning

This project adheres to [Semantic Versioning](http://semver.org/).

## Author

[Reid Morrison](https://github.com/reidmorrison)

## License

Copyright 2020 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
