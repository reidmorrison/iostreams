# iostreams
[![Gem Version](https://img.shields.io/gem/v/iostreams.svg)](https://rubygems.org/gems/iostreams) [![Build Status](https://travis-ci.org/rocketjob/iostreams.svg?branch=master)](https://travis-ci.org/rocketjob/iostreams) [![Downloads](https://img.shields.io/gem/dt/iostreams.svg)](https://rubygems.org/gems/iostreams) [![License](https://img.shields.io/badge/license-Apache%202.0-brightgreen.svg)](http://opensource.org/licenses/Apache-2.0) ![](https://img.shields.io/badge/status-Beta-yellow.svg) [![Gitter chat](https://img.shields.io/badge/IRC%20(gitter)-Support-brightgreen.svg)](https://gitter.im/rocketjob/support)

Input and Output streaming for Ruby.

## Project Status

Production Ready, but API is subject to breaking changes until V1 is released.

## Features

Supported file / stream types:

* Zip
* Gzip
* BZip2
* CSV
* PGP (Uses GnuPG)
* Xlsx (Reading)
* Encryption using [Symmetric Encryption](https://github.com/reidmorrison/symmetric-encryption)

Streaming support currently under development:

* S3
* SFTP

Supported file formats:

* CSV
* Fixed width formats
* JSON
* PSV

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
IOStreams.reader('hello.gz') do |reader|
  data = reader.read(1024)
  puts "Read: #{data}"
end
```

The true power of streams is shown when many streams are chained together to achieve the end
result, without holding the entire file in memory, or ideally without needing to create
any temporary files to process the stream.

```ruby
# Create a file that is compressed with GZip and then encrypted with Symmetric Encryption:
IOStreams.writer('hello.gz.enc') do |writer|
  writer.write('Hello World')
  writer.write('and some more')
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
require 'iostreams'
IOStreams.reader('abc.csv') do |io|
  p data while (data = io.read(128))
end
~~~

While decompressing the file, display one line at a time from the file.

~~~ruby
IOStreams.each_line('abc.csv') do |line|
  puts line
end
~~~

While decompressing the file, display each row from the csv file as an array.

~~~ruby
IOStreams.each_row('abc.csv') do |array|
  p array
end
~~~

While decompressing the file, display each record from the csv file as a hash.
The first line is assumed to be the header row.

~~~ruby
IOStreams.each_record('abc.csv') do |hash|
  p hash
end
~~~

Display each line from the array as a hash.
The first line is assumed to be the header row.

~~~ruby
array = [
  'name, address, zip_code',
  'Jack, Down Under, 12345'
]
IOStreams.each_record(array) do |hash|
  p hash
end
~~~

Write data while compressing the file.

~~~ruby
IOStreams.writer('abc.csv') do |io|
  io.write('This')
  io.write(' is ')
  io.write(" one line\n")
end
~~~

Write a line at a time while compressing the file.

~~~ruby
IOStreams.line_writer('abc.csv') do |file|
  file << 'these'
  file << 'are'
  file << 'all'
  file << 'separate'
  file << 'lines'
end
~~~

Write an array (row) at a time while compressing the file.
Each array is converted to csv before being compressed with zip.

~~~ruby
IOStreams.row_writer('abc.csv') do |io|
  io << %w[name address zip_code]
  io << %w[Jack There 1234]
  io << ['Joe', 'Over There somewhere', 1234]
end
~~~

Write a hash (record) at a time while compressing the file.
Each hash is converted to csv before being compressed with zip.
The header row is extracted from the first hash supplied.

~~~ruby
IOStreams.record_writer('abc.csv') do |stream|
  stream << {name: 'Jack', address: 'There', zip_code: 1234}
  stream << {name: 'Joe', address: 'Over There somewhere', zip_code: 1234}
end
~~~

Write to a string IO for testing, supplying the filename so that the streams can be determined.

~~~ruby
io = StringIO.new
IOStreams::Tabular::Writer(io, file_name: 'abc.csv') do |stream|
  stream << {name: 'Jack', address: 'There', zip_code: 1234}
  stream << {name: 'Joe', address: 'Over There somewhere', zip_code: 1234}
end
puts io.string
~~~

Read a CSV file and write the output to an encrypted file in JSON format.

~~~ruby
IOStreams.record_writer('sample.json.enc') do |output|
  IOStreams.each_record('sample.csv') do |record|
    output << record
  end
end
~~~

## Copying between files

Stream based file copying. Changes the file type without changing the file format. For example, compress or encrypt. 

Encrypt the contents of the file `sample.json` and write to `sample.json.enc`

~~~ruby
IOStreams.copy('sample.json', 'sample.json.enc')
~~~

Encrypt and compress the contents of the file `sample.json` with Symmetric Encryption and write to `sample.json.enc`

~~~ruby
IOStreams.copy('sample.json', 'sample.json.enc', target_options: {streams: {enc: {compress: true}}})
~~~

Encrypt and compress the contents of the file `sample.json` with pgp and write to `sample.json.enc`

~~~ruby
IOStreams.copy('sample.json', 'sample.json.pgp', target_options: {streams: {pgp: {recipient: 'sender@example.org'}}})
~~~

Decrypt the file `abc.csv.enc` and write it to `xyz.csv`.

~~~ruby
IOStreams.copy('abc.csv.enc', 'xyz.csv')
~~~

Read `ABC`, PGP encrypt the file and write to `xyz.csv.pgp`, applying 

~~~ruby
IOStreams.copy('ABC', 'xyz.csv.pgp',
               source_options: [:enc],
               target_options: [pgp: {email_recipient: 'a@a.com'})
~~~

## Notes

* Due to the nature of Zip, both its Reader and Writer methods will create
  a temp file when reading from or writing to a stream.
  Recommended to use Gzip over Zip since it can be streamed.
* Zip becomes exponentially slower with very large files, especially files
  that exceed 4GB when uncompressed. Highly recommend using GZip for large files.

To completely implement io streaming for Ruby will take a lot more input and thoughts
from the Ruby community. This gem represents a starting point to get the discussion going.

By keeping this gem a 0.x version and not going V1, we can change the interface as needed
to implement community feedback.

## Versioning

This project adheres to [Semantic Versioning](http://semver.org/).

## Author

[Reid Morrison](https://github.com/reidmorrison)

## License

Copyright 2018 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
