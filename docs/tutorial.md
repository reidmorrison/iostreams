---
layout: default
---

## File / Data Streaming with Ruby

If all files were small, they could just be loaded into memory in their entirety. 
However, multi Gigabytes, or even Terabytes in size, loading them into memory is not feasible.
 
In linux it is common to use pipes to stream data between processes. 
For example:

~~~
# Count the number of lines in a file that has been compressed with gzip
cat abc.gz | gunzip -c | wc -l
~~~

For large files it is critical to be able to read and write these files as streams. Ruby has support
for reading and writing files using streams, but has no built-in way of passing one stream through
another to support for example compressing the data, encrypting it and then finally writing the result
to a file. Several streaming implementations exist for languages such as `C++` and `Java` to chain
together several streams, `IOStreams` attempts to offer similar features for Ruby.

~~~ruby
# Read a compressed file:
IOStreams.path("hello.gz").reader do |io|
  data = io.read(1024)
  puts "Read: #{data}"
end
~~~

The true power of streams is shown when many streams are chained together to achieve the end
result, without holding the entire file in memory, or ideally without needing to create
any temporary files to process the stream.

~~~ruby
# Create a file that is compressed with GZip and then encrypted with Symmetric Encryption:
IOStreams.path("hello.gz.enc").writer do |io|
  io << "Hello World"
  io << "and some more"
end
~~~

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

## Step by Step 

Install IOStreams gem:
~~~
gem install iostreams --no-doc
~~~

If you want to follow the AWS S3 examples below install the AWS S3 gem:
~~~
gem install aws-sdk-s3 --no-doc
~~~

#### TODO: Document AWS S3 configuration.

Open a ruby interactive console:

~~~
irb
~~~
 
Load iostreams:

~~~ruby
require "iostreams"
~~~
 
Reference a file path to hold CSV data and then for fun lets also compress it with GZip: 
~~~ruby
path = IOStreams.path("sample/example.csv.gz")
# => #<IOStreams::Paths::File:sample/example.csv.gz pipeline={:gz=>{}}> 
~~~

The path and file name does not exist yet:
~~~ruby
path.exist?
# => false 
~~~

If the path `sample` does not exist, it is created automatically during the first write. 
Write CSV data to the file, compressing to GZip as we go.
~~~ruby
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

To verify the data written above, read the entire file:
~~~ruby
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

It would be much easier if we could write the CSV data as hashes and let IOStreams deal
with all the details on how to create properly formatted CSV data: 
~~~ruby
path.writer(:hash) do |io|
  io << {name: "Jack Jones", login: "jjones"}
  io << {name: "Jill Smith", login: "jsmith"}
end 
~~~

Verify the data written by reading the entire file:
~~~ruby
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

Now lets read the file one line at a time:
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

But who wants to do CSV parsing by hand, lets get IOStreams to do that for us by passing `:array` to `each`:
~~~ruby
path.each(:array) do |array|
  p array
end
~~~
Output:
~~~ruby
["name", "login"]
["Jack Jones", "jjones"]
["Jill Smith", "jsmith"]
~~~

That was better, but we really want a hash back where IOStreams takes care of the CSV header:
~~~ruby
path.each(:hash) do |hash|
  p hash
end
~~~
Output:
~~~ruby
{"name"=>"Jack Jones", "login"=>"jjones"}
{"name"=>"Jill Smith", "login"=>"jsmith"}
~~~

As the file gets larger and we reach millions of rows the above code does not have to change at all. 
And memory utilization stays about the same since each block is read in, decompressed, and parsed 
from CSV one block at a time. The garbage collector can then free the released blocks from memory. 

Now lets read a zip file hosted on an HTTP Web Server, displaying the first row as a hash: 

~~~ruby
IOStreams.
  path("https://www5.fdic.gov/idasp/Offices2.zip").
  option(:zip, entry_file_name: "OFFICES2_ALL.CSV").
  each(:hash) do |row|
    p row
    # Just show the first line for this tutorial
    break
  end
~~~
Output:
~~~ruby
{"address"=>"1 Lincoln St. Fl 1", "bkclass"=>"SM", "cbsa"=>"Boston-Cambridge-Newton, MA-NH", "cbsa_div"=>"Boston, MA", "cbsa_div_flg"=>"1", "cbsa_div_no"=>"14454", "cbsa_metro"=>"14460", "cbsa_metro_flg"=>"1", "cbsa_metro_name"=>"Boston-Cambridge-Newton, MA-NH", "cbsa_micro_flg"=>"0", "cbsa_no"=>"14460", "cert"=>"14", "city"=>"Boston", "county"=>"Suffolk", "csa"=>"Boston-Worcester-Providence, MA-RI-NH-CT", "csa_flg"=>"1", "csa_no"=>"148", "estymd"=>"1792-01-01", "fi_uninum"=>"6", "mainoff"=>"1", "name"=>"State Street Bank And Trust Company", "offname"=>"State Street Bank And Trust Company", "offnum"=>nil, "rundate"=>"2020-05-14", "servtype"=>"11", "stalp"=>"MA", "stcnty"=>"25025", "stname"=>"Massachusetts", "uninum"=>"6", "zip"=>"2111"}
~~~

Noticed that it took a while to return the first line?

That is because `zip` requires the entire file to be downloaded before it can decompress anything
in the file. And HTTP uses a push protocol when reading files, so it is downloaded automatically
into a temp file behind the scenes so that we can read it as if it was a local file.

## Same Code - Any File Type

Lets define a method to write data to a file.
~~~ruby
def write_lines(file_name)
  path = IOStreams.path(file_name)
  path.writer do |io|
    io << "name,login\n"
    io << "Jack Jones,jjones\n"
    io << "Jill Smith,jsmith\n"
  end
end
~~~

Create some sample files to work with
~~~ruby
write_lines("sample/example.csv")
write_lines("sample/example.csv.gz")
~~~

For PGP files we also need to specify the recipient that can decrypt the file.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org")
write_lines(path)
~~~

`IOStreams.path` takes a string as its argument, it can also accept an existing instance of `IOStreams`.
That allows the same method to accept the pgp recipient without having to pass the pgp specific recipient information
as an argument to the method.

Consider a simple method to display the contents of a file a line at a time 
prefixed with the line number within the file:
~~~ruby
def show_lines(file_name)
  line_number = 1
  path = IOStreams.path(file_name)
  path.each(:line) do |line|
    puts "[#{line_number}] #{line}"
    line_number += 1
  end
end
~~~

Lets read all of the files created above with the new `show_lines` method:

~~~ruby
show_lines("sample/example.csv")
show_lines("sample/example.csv.gz")
show_lines("sample/example.csv.pgp")
~~~

Noticed how they all returned the exact same output, even though the first file was plain text, the second was
compressed with Gzip and the third was encrypted with PGP. They all returned:
~~~
[1] name,login
[2] Jack Jones,jjones
[3] Jill Smith,jsmith
~~~

Now a program can be developed using IOStreams and then without any code changes is able read plain text, compressed,
or encrypted files.

## Same Code - Any File Storage

Using the unchanged `write_lines` and `show_lines` methods above, lets use them to read and write from S3.

But how is that possible since our program / methods above were only tested against local files?

Create the same sample files to work with, but this time on AWS S3 in a bucket name `my-iostreams-bucket`
~~~ruby
write_lines("s3://my-iostreams-bucket/sample/example.csv")
write_lines("s3://my-iostreams-bucket/sample/example.csv.gz")
~~~

For PGP files we also need to specify the recipient that can decrypt the file.
~~~ruby
path = IOStreams.path("s3://my-iostreams-bucket/sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org")
write_lines(path)
~~~

The only change to switch to S3 storage was to prefix the file name passed in with `s3://my-iostreams-bucket/`.

Lets read all of the files created above with the new `show_lines` method:

~~~ruby
show_lines("s3://my-iostreams-bucket/sample/example.csv")
show_lines("s3://my-iostreams-bucket/sample/example.csv.gz")
show_lines("s3://my-iostreams-bucket/sample/example.csv.pgp")
~~~

Noticed how they all returned the exact same output, even though the first file was plain text, the second was
compressed with Gzip and the third was encrypted with PGP. They all returned:
~~~
[1] name,login
[2] Jack Jones,jjones
[3] Jill Smith,jsmith
~~~

Now a program can be developed using IOStreams and then without any code changes is able to read and write across
multiple storage locations.

## Tabular Files

Tabular files are any files that start with a header row and then follows with rows of data with each row
on a separate line.

For example "example.csv"
~~~
name,login
Jack Jones,jjones
Jill Smith,jsmith
~~~

The first line contains the header: `name,login`
Each subsequent line contains the data delimited by a special character such as `,` in the same order as the header.

Another example is PSV (Pipe Separated Files)
~~~
name|login
Jack Jones|jjones
Jill Smith|jsmith
~~~

Of course these are simple examples and there are lots of rules on how to embed or escape the row or column delimiters.

### Reading Tabular Files

When reading these files, IOStreams can handle the complexity of the files format and always return the data as a
`hash`, or `array`.

Lets create another method along the lines of `show_lines` above:
~~~ruby
def show_rows(file_name)
  line_number = 1
  path = IOStreams.path(file_name)
  path.each(:hash) do |row|
    puts "[#{line_number}] #{row.inspect}"
    line_number += 1
  end
end
~~~

The key difference is that `:hash` is being passed into `each` instead of `:line`.

Using the sample files created above:
~~~ruby
show_rows("sample/example.csv")
~~~

Outputs:
~~~
[1] {"name"=>"Jack Jones", "login"=>"jjones"}
[2] {"name"=>"Jill Smith", "login"=>"jsmith"}
~~~

Notice how only 2 rows are returned, since the header row is not actual data, it is just the definition of the
rows that follow.

The same method works without changes regardless of where the file was stored, or whether it was encrypted or
compressed.
~~~ruby
show_rows("s3://my-iostreams-bucket/sample/example.csv")
show_rows("s3://my-iostreams-bucket/sample/example.csv.gz")
show_rows("s3://my-iostreams-bucket/sample/example.csv.pgp")
~~~

### Writing Tabular Files

Lets define a new method that uses a tabular api to write the data.
~~~ruby
def write_tabular(file_name)
  path = IOStreams.path(file_name)
  path.writer(:hash) do |io|
    io << {"name"=>"Jack Jones", "login"=>"jjones"}
    io << {"name"=>"Jill Smith", "login"=>"jsmith"}
  end
end
~~~

The key difference is that `:hash` is being passed into `writer` to indicate that it will receive hashes instead of
raw data.

Lets create a sample file, and then read it to compare its contents to the raw writer above.
~~~ruby
write_tabular("sample/example.csv")
IOStreams.path("sample/example.csv").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

Note how the output file is identical to the one created above. 
Using `writer(:hash)` makes it easier to develop the application without regard for:
- The order of columns
- Missing columns
- Specialized escaping of values to handle row or column delimiters

Note: The first row written determines the column names as well as the order of the elements to be written.
See `IOStreams.writer` for details on how to supply the header columns up front to set the order or to filter out
which columns should be written to the target file.

Now lets write the same data into a JSON file, then read it to see what it looks like:
~~~ruby
write_tabular("sample/example.json")
puts IOStreams.path("sample/example.json").read
# => "{\"name\":\"Jack Jones\",\"login\":\"jjones\"}\n{\"name\":\"Jill Smith\",\"login\":\"jsmith\"}\n"
~~~

Using the same `show_rows` method above to display the file line by line
~~~ruby
show_rows("sample/example.json")
~~~

Outputs the same data even though the file is now json instead of the previous file that was csv:
~~~
[1] {"name"=>"Jack Jones", "login"=>"jjones"}
[2] {"name"=>"Jill Smith", "login"=>"jsmith"}
~~~

The same method works without changes regardless of where the file was stored, or whether it was encrypted or
compressed, or whether the format was csv or json.
~~~ruby
show_rows("sample/example.csv")
show_rows("sample/example.json")
show_rows("s3://my-iostreams-bucket/sample/example.csv")
show_rows("s3://my-iostreams-bucket/sample/example.json.gz")
show_rows("s3://my-iostreams-bucket/sample/example.json.pgp")
~~~

## Conclusion

IOStreams makes it possible to write an application to a common api so that
* the file can be accessed anywhere ( at least a local file, AWS S3, HTTP(S) and SFTP for now).
* the application does not care if or how the file was compressed.
* the application does not care if or how the file was encrypted.
* the actual file storage mechanism can be determined at runtime, or per environment.
* it is transparent whether the application receives an Excel Spreadsheet, CSV, or PSV formatted file.
  It just works with hashes when desired.  

IOStreams is an incredibly powerful streaming library to make runtime file formats, compression, or encryption changes transparent.
