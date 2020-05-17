---
layout: default
---

# Streams

Read 128 characters at a time from the file:
~~~ruby
IOStreams.path("example.csv").reader do |io|
  while (data = io.read(128))
    p data 
  end
end
~~~

Read one line at a time from the file:
~~~ruby
IOStreams.path("example.csv").each do |line|
  puts line
end
~~~

Display each row from the csv file as an array:
~~~ruby
IOStreams.path("example.csv").each(:array) do |array|
  p array
end
~~~

Display each row from the csv file as a hash, where the first line in the CSV file is the header:
~~~ruby
IOStreams.path("example.csv").each(:hash) do |hash|
  p hash
end
~~~

Write data to the file.
~~~ruby
IOStreams.path("abc.txt").writer do |io|
  io << "This"
  io << " is "
  io << " one line\n"
end
~~~

Write lines to the file. By adding `:line` to `writer`, each write appends a new line character. 
~~~ruby
IOStreams.path("example.csv").writer(:line) do |file|
  file << "these"
  file << "are"
  file << "all"
  file << "separate"
  file << "lines"
end
~~~

Write an array (row) at a time to the file.
Each array is converted to csv before being compressed with zip.

~~~ruby
IOStreams.path("example.csv").writer(:array) do |io|
  io << ["name", "address", "zip_code"]
  io << ["Jack", "There", "1234"]
  io << ["Joe", "Over There somewhere", 1234]
end
~~~

Write a hash (record) at a time to the file.
Each hash is converted to csv before being compressed with zip.
The header row is extracted from the first hash write that is performed. 

~~~ruby
IOStreams.path("example.csv").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {zip_code: 1234, address: "Over There somewhere", name: "Joe"}
end
~~~

Notes
* Any additional keys supplied during subsequent write operations will be ignored
  since the header row has already been written to the file. 
* The order of the header and values is determined by the order of the keys supplied 
  during the first write.
* The order of keys in the subsequent writes does not matter. 

Stream into an in-memory buffer, useful for testing. 
The original filename still needs to be supplied so that the streaming pipeline can still be inferred.

~~~ruby
io = StringIO.new
IOStreams.stream(io, file_name: "example.csv.gz").writer(:hash) do |stream|
  stream << {name: "Jack", address: "There", zip_code: 1234}
  stream << {name: "Joe", zip_code: 1234, address: "Over There somewhere"}
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

Read a zip file hosted on a HTTP Web Server, returning each row as a hash:
~~~ruby
IOStreams.
  path("https://www5.fdic.gov/idasp/Offices2.zip").
  option(:zip, entry_file_name: "OFFICES2_ALL.CSV").
  each(:hash) do |row|
    p row
  end
~~~

Notes:
* By default IOStreams will read the first file in the zip file. 
* To choose a specific file name within the zip file, supply: `entry_file_name` 

## Notes

* Due to the nature of Zip, both its Reader and Writer methods will create
  a temp file when reading from or writing to a stream.
  Recommended to use Gzip over Zip since it can be streamed without requiring temp files.
* Zip becomes exponentially slower with very large files, especially files
  that exceed 4GB when uncompressed. Highly recommend using GZip for large files.
