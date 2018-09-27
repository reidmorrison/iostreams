## Architecture

Every Reader or Writer is invoked by calling its `.open` method and passing the block
that must be invoked for the duration of that stream.

The above block is passed the stream that needs to be encoded/decoded using that
Reader or Writer every time the `#read` or `#write` method is called on it.

~~~ruby
IOStreams::Xlsx::Reader.open('a.xlsx') do |stream|
  IOStreams::Record::Reader.open(stream, format: :array) do |record_stream|
    record_stream.each { |record| ap record }
  end
end
~~~

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
