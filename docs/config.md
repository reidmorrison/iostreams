---
layout: default
---

## Configuring IOStreams

### add_root

When using `IOStreams.join` it uses a default root from which to join the remainder of the path.

Set the default root for this environment
~~~ruby
IOStreams.add_root(:default, "/var/my_app/files")
~~~

Now the default root path is available:
~~~ruby
IOStreams.root
# => #<IOStreams::Paths::File:/var/my_app/files pipeline={}>
 
IOStreams.root.to_s
# => "/var/my_app/files"
~~~

Comparing the final path using `path` and then `join` that uses a root path:
~~~ruby
IOStreams.path("/var/my_app/files", "my_test_file.txt").to_s
# => "/var/my_app/files/my_test_file.txt"

IOStreams.join("my_test_file.txt").to_s
# => "/var/my_app/files/my_test_file.txt"
~~~


Using `path`:
~~~ruby
IOStreams.path("/var/my_app/files", "my_test_file.txt").write("Hello World")
~~~

With the default root path configured the above code can be simplified by using `join` since it resolves to the same path.
~~~ruby
IOStreams.join("my_test_file.txt").write("Hello World")
~~~

Other root paths can be added for special purposes.
 
For example add special paths for `downloads` and `uploads`.
~~~ruby
IOStreams.add_root(:downloads, "/var/my_app/downloads")
IOStreams.add_root(:uploads, "/var/my_app/uploads")
~~~

An example that writes a file into the `/var/my_app/downloads` directory:
~~~ruby
IOStreams.join("my_test_file.txt", root: :downloads).write("Hello World")
~~~

The other benefit is that the root paths used in an application are externalized from the code base. That way the
roots can be changed to different locations depending on the environment.

We can also change the storage mechanism by changing the root:
~~~ruby
IOStreams.add_root(:downloads, "s3://my-app-bucket-name/downloads")
IOStreams.add_root(:uploads, "s3://my-app-bucket-name/uploads")
~~~

Now the application will write to S3 and the code does not change at all.
~~~ruby
IOStreams.join("my_test_file.txt", root: :downloads).write("Hello World")
~~~

To use or query a configured root path:
~~~ruby
IOStreams.root(:downloads).to_s
# => "s3://my-app-bucket-name/downloads"
~~~

## temp_dir

When working with large files the standard temp file system location can be too small to handle downloading large
files. For example to decrypt a pgp file from S3, because GnuPG is not streaming capable and only operates on local filess.

By default IOStreams looks up the location to store temp files in the following order:
* `ENV['TMPDIR']`
* `ENV['TMP']`
* `ENV['TEMP']`
* `Etc.systmpdir`
* `/tmp` (if it exists)
* Otherwise `.`

To explicity set the temp file location the following config option can be used:

~~~ruby
IOStreams.temp_dir = "/var/really_big_temp"
~~~
