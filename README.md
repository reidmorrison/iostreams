# iostreams [![Gem Version](https://badge.fury.io/rb/iostreams.svg)](http://badge.fury.io/rb/iostreams) [![Build Status](https://secure.travis-ci.org/rocketjob/iostreams.png?branch=master)](http://travis-ci.org/rocketjob/iostreams) ![](http://ruby-gem-downloads-badge.herokuapp.com/iostreams?type=total)

Ruby Input and Output streaming for Ruby 

## Project Status

Beta - Feedback on the API is welcome. API is subject to change.

## Features

Currently streaming classes are available for:

* Zip
* Gzip
* BZip2
* CSV
* Delimited Lines / Rows
* PGP
* Xlsx (Reading)
* Encryption using [Symmetric Encryption](https://github.com/reidmorrison/symmetric-encryption)

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

## Architecture

Streams are chained together by passing the 

Every Reader or Writer is invoked by calling its `.open` method and passing the block
that must be invoked for the duration of that stream.

The above block is passed the stream that needs to be encoded/decoded using that
Reader or Writer every time the `#read` or `#write` method is called on it.

### Readers

Each reader stream must implement: `#read`

### Writer

Each writer stream must implement: `#write`

### Optional methods

The following methods on the stream are useful for both Readers and Writers

### close

Close the stream, and cleanup any buffers, etc.

### closed?

Has the stream already been closed? Useful, when child streams have already closed the stream
so that `#close` is not called more than once on a stream.

## Notes

* Due to the nature of Zip, both its Reader and Writer methods will create
  a temp file when reading from or writing to a stream.
  Recommended to use Gzip over Zip since it can be streamed.
* Zip becomes exponentially slower with very large files, especially files
  that exceed 4GB when uncompressed. Highly recommend using GZip for large files.

## Future

Below are just some of the streams that are envisaged for `iostreams`:
* PGP reader and write
    * Read and write PGP encrypted files
* CSV
    * Read and write CSV data, reading data back as Arrays and writing Arrays as CSV text
* Delimited Text Stream
    * Autodetect Windows/Linux line endings and return a line at a time
* MongoFS
    * Read and write file streams to and from MongoFS
    
For example:
```ruby
# Read a CSV file, delimited with Windows line endings, compressed with GZip, and encrypted with PGP:
IOStreams.reader('hello.csv.gz.pgp', [:csv, :delimited, :gz, :pgp]) do |reader|
  # Returns an Array at a time
  reader.each do |row|
    puts "Read: #{row.inspect}"
  end
end
```

To completely implement io streaming for Ruby will take a lot more input and thoughts
from the Ruby community. This gem represents a starting point to get the discussion going.

By keeping this gem in Beta state and not going V1, we can change the interface as needed
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
