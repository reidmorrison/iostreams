---
layout: default
---

# Path

A path identifies _where_ a file is stored and how to reach it, so that the streaming pipeline knows
where to read the data from or write it to.

Create a path with `IOStreams.path`, passing the file name, which may also be a URI, followed by any
arguments specific to that storage location. IOStreams infers the storage mechanism from the URI
scheme, so the same call returns a local file path, an S3 path, an SFTP path, and so on, all sharing
the identical interface.

IOStreams supports accessing files in the following places:

* File
* AWS S3
* Google Cloud Storage (Using the AWS S3 Client)
* SFTP
* HTTP(S) (Read only)

Are you using another cloud provider and want to add support for your favorite?
Checkout the supplied [IOStreams S3 path provider](https://github.com/reidmorrison/iostreams/blob/main/lib/io_streams/paths/s3.rb)
for an example of what is required. Pull requests welcome.

### File

The simplest case is a file on the local disk:

~~~ruby
path = IOStreams.path("somewhere/example.csv")
~~~

#### Optional Arguments:

* `:create_path` set to false to stop IOStreams from automatically creating the output directories 
  if they do not exist.
  Default: true   
~~~ruby
path = IOStreams.path("somewhere/example.csv.gz", create_path: false)
~~~

### AWS S3 (s3://)

If the supplied file name string includes a URI. For example if AWS is configured locally:

~~~ruby
path = IOStreams.path("s3://bucket-name/path/example.csv")
~~~

#### Required Arguments:

* url [String]

  Prefix must be: `s3://`, followed by bucket name, followed by key.
  Examples:
    s3://my-bucket-name/file_name.txt
    s3://my-bucket-name/some_path/file_name.csv

#### Optional Arguments:

* :access_key_id [String]

  AWS Access Key Id to use to access this bucket.

* :secret_access_key [String]

  AWS Secret Access Key Id to use to access this bucket.

* :region [String]

  The AWS region to connect to.
  Default: the region set in the environment variables or credential files.

* :client [Aws::S3::Client | Hash]

  Supply the AWS S3 Client instance to use for this path.
  Or, when a Hash, build a new client using the hash parameters.

~~~ruby
client = Aws::S3::Client.new(endpoint: "https://s3.test.com")
path   = IOStreams.path("s3://bucket/path/file_name.txt", client: client)

# Or, pass the client parameters directly:
path = IOStreams.path("s3://bucket/path/file_name.txt", client: {endpoint: "https://s3.test.com"})
~~~

Writer specific options:

* :acl [String]

  The canned ACL to apply to the object.

* :cache_control [String]

  Specifies caching behavior along the request/reply chain.

* :content_disposition [String]

  Specifies presentational information for the object.

* :content_encoding [String]

  Specifies what content encodings have been applied to the object and
  thus what decoding mechanisms must be applied to obtain the media-type
  referenced by the Content-Type header field.

* :content_language [String]

  The language the content is in.

* :content_length [Integer]
 
  Size of the body in bytes. This parameter is useful when the size of
  the body cannot be determined automatically.

* :content_md5 [String]

  The base64-encoded 128-bit MD5 digest of the part data. This parameter
  is auto-populated when using the command from the CLI. This parameted
  is required if object lock parameters are specified.

* :content_type [String]

  A standard MIME type describing the format of the object data.

* :expires [Time,DateTime,Date,Integer,String]

  The date and time at which the object is no longer cacheable.

* :grant_full_control [String]

  Gives the grantee READ, READ\_ACP, and WRITE\_ACP permissions on the
  object.

* :grant_read [String]

  Allows grantee to read the object data and its metadata.

* :grant_read_acp [String]

  Allows grantee to read the object ACL.

* :grant_write_acp [String]

  Allows grantee to write the ACL for the applicable object.

* :metadata [Hash<String,String>]

  A map of metadata to store with the object in S3.

* :server_side_encryption [String]

  The Server-side encryption algorithm used when storing this object in
  S3 (e.g., AES256, aws:kms).

* :storage_class [String]

  The type of storage to use for the object. Defaults to 'STANDARD'.

* :website_redirect_location [String]

  If the bucket is configured as a website, redirects requests for this
  object to another object in the same bucket or to an external URL.
  Amazon S3 stores the value of this header in the object metadata.

* :sse_customer_algorithm [String]

  Specifies the algorithm to use to when encrypting the object (e.g.,
  AES256).

* :sse_customer_key [String]

  Specifies the customer-provided encryption key for Amazon S3 to use in
  encrypting data. This value is used to store the object and then it is
  discarded; Amazon does not store the encryption key. The key must be
  appropriate for use with the algorithm specified in the
  x-amz-server-side​-encryption​-customer-algorithm header.

* :sse_customer_key_md5 [String]

  Specifies the 128-bit MD5 digest of the encryption key according to
  RFC 1321. Amazon S3 uses this header for a message integrity check to
  ensure the encryption key was transmitted without error.

* :ssekms_key_id [String]

  Specifies the AWS KMS key ID to use for object encryption. All GET and
  PUT requests for an object protected by AWS KMS will fail if not made
  via SSL or using SigV4. Documentation on configuring any of the
  officially supported AWS SDKs and CLI can be found at
  http://docs.aws.amazon.com/AmazonS3/latest/dev/UsingAWSSDK.html#specify-signature-version

* :ssekms_encryption_context [String]

  Specifies the AWS KMS Encryption Context to use for object encryption.
  The value of this header is a base64-encoded UTF-8 string holding JSON
  with the encryption context key-value pairs.

* :request_payer [String]

  Confirms that the requester knows that she or he will be charged for
  the request. Bucket owners need not specify this parameter in their
  requests. Documentation on downloading objects from requester pays
  buckets can be found at
  http://docs.aws.amazon.com/AmazonS3/latest/dev/ObjectsinRequesterPaysBuckets.html

* :tagging [String]

  The tag-set for the object. The tag-set must be encoded as URL Query
  parameters. (For example, "Key1=Value1")

* :object_lock_mode [String]

  The object lock mode that you want to apply to this object.

* object_lock_retain_until_date: [Time,DateTime,Date,Integer,String]

  The date and time when you want this object's object lock to expire.

* object_lock_legal_hold_status: [String]
  The Legal Hold status that you want to apply to the specified object.

### SFTP (sftp://)

If the supplied file name string includes the `sftp` URI.

~~~ruby
path = IOStreams.path("sftp://hostname/path/example.csv")
~~~

IOStreams reads and writes SFTP files by shelling out to the `sftp` command line program,
so it must be installed and on the `PATH`. When a password is supplied the `sshpass`
program is also required to pass the password to `sftp`. Additionally the `net-sftp` gem
must be added to the `Gemfile` to use `each_child`.

Read a file from a remote sftp server.
~~~ruby
IOStreams.path("sftp://example.org/path/file.txt", 
               username: "jbloggs", 
               password: "secret").
  reader do |input|
    puts input.read
  end
~~~

Raises `IOStreams::Errors::CommunicationsFailure` when the file could not be read or written.

Write to a file on a remote sftp server.
~~~ruby
IOStreams.path("sftp://example.org/path/file.txt", 
               username: "jbloggs", 
               password: "secret").
  writer do |output|
    output.write('Hello World')
  end
~~~

Display the contents of a remote file, supplying the username and password in the url:
~~~ruby
IOStreams.path("sftp://jack:OpenSesame@test.com:22/path/file_name.csv").reader do |io|
  puts io.read
end
~~~

Use an identity file instead of a password to authenticate:
~~~ruby
path = IOStreams.path("sftp://test.com/path/file_name.csv", 
                      username: "jack", 
                      ssh_options: {IdentityFile: "~/.ssh/private_key"})
path.reader do |io|
  puts io.read
end
~~~

Pass in the IdentityKey itself instead of a password to authenticate. 
For example, retrieve the identity key stored in Secret Config: 
~~~ruby
identity_key = SecretConfig.fetch("suppliers/sftp/identity_key")

path = IOStreams.path("sftp://test.com/path/file_name.csv", 
                      username: "jack", 
                      ssh_options: {IdentityKey: identity_key})
path.reader do |io|
  puts io.read
end
~~~

#### Required Arguments:

* url [String]

  Prefix must be: `sftp://`, followed by host name, followed by file name.
  Format:
    "sftp://<host_name>/<file_name>"
    "sftp://username:password@hostname:22/path/file_name"

#### Optional Arguments:

* username: [String]

  Name of user to login with.

* password: [String]

  Password for the user.

* ssh_options: [Hash]

  * IdentityFile [String]

    Path to the local identity (private key) file to authenticate with, instead of a password.

  * IdentityKey [String]

    The identity (private key) itself, supplied as a string.
    Under the covers the key is written to a temp file and then passed as `IdentityFile`.

  * HostKey [String]

    The expected SSH host key presented by the remote host, instead of storing it in the
    `known_hosts` file. It must contain the entire line that would be stored in `known_hosts`,
    including the hostname, ip address, key type and key value. The easiest way to generate
    the required value is with `ssh-keyscan hostname`.
    Under the covers the value is written to a temp file and then passed as `UserKnownHostsFile`.

  * Any other options supported by ssh_config.
    `man ssh_config` to see all available options.

Notes:
* Since the `sftp` program operates on local files, reading from or writing to an SFTP path
  streams through a local temp file behind the scenes.

### HTTP (http://, https://)

Read from a remote file over HTTP or HTTPS using an HTTP Get.

~~~ruby
IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').read
~~~

Notes:
* Since Net::HTTP download only supports a push stream, the data is streamed into a tempfile first.
* Currently writing to an HTTP(S) server is not supported. Up to submitting a Pull Request with capability?

#### Required Arguments:

* url [String]

  Prefix must be: `http://`, or `https://` followed by host name, followed by path and file name.
  Also supports passing the username and password for basic authentication in the URI.
  
  Format:
  * http://hostname/path/file_name
  * https://username:password@hostname/path/file_name

#### Optional Arguments:

* username: [String]

  When supplied, basic authentication is used with the username and password.

* password: [String]

  Password to use use with basic authentication when the username is supplied.

* parameters: [Hash]

  Query parameters to append to the url as a query string.
  For example, `parameters: {"type" => "csv"}` appends `?type=csv` to the url.

* http_redirect_count: [Integer]

  Maximum number of http redirects to follow.
  Set to `0` to disable following redirects entirely.
  Default: `10`

* allow_hosts: [String | Array<String>]

  Optional allow-list of host names that may be contacted. It is applied both to the
  supplied url and to every redirect that is followed; a request to any other host raises
  `IOStreams::Errors::CommunicationsFailure`.
  Default: `nil` (any host is allowed).

* maximum_file_size: [Integer]

  Optional maximum number of bytes to download. When the response body exceeds this size the
  download is aborted with an `IOStreams::Errors::CommunicationsFailure`.
  Default: `nil` (no limit).

~~~ruby 
path = IOStreams.path("http://hostname/path/example.csv")
~~~

#### Security: untrusted URLs (SSRF)

Reading an HTTP(S) path causes the application to issue a request to the host named in the url.
When the url, or any part of it, can be influenced by untrusted input, an attacker can point it
at internal services or cloud metadata endpoints (Server Side Request Forgery).

Because redirect targets are chosen by the remote server, validating only the url that is passed
in is not sufficient: a trusted (or compromised) server can redirect the request to an internal
address. IOStreams provides a few controls to reduce this exposure:

* Restrict which hosts may be contacted, including across redirects:

~~~ruby
IOStreams.path("https://supplier.example.com/report.csv", allow_hosts: ["supplier.example.com"]).read
~~~

* Disable redirects entirely for untrusted urls:

~~~ruby
IOStreams.path(untrusted_url, http_redirect_count: 0).read
~~~

* Cap the download size to avoid unbounded (denial of service) responses:

~~~ruby
IOStreams.path(untrusted_url, maximum_file_size: 50 * 1024 * 1024).read
~~~

Basic authentication credentials are only ever sent to the original host. They are not resent
when a redirect points at a different scheme, host, or port, so a redirect cannot leak them to
another server. For stronger guarantees, route these downloads through an egress proxy or network
policy that blocks private, loopback, and link-local (cloud metadata) addresses.

Similarly when using https:

~~~ruby 
path = IOStreams.path("https://hostname/path/example.csv")
~~~

This time IOStreams inferred that the file lives on an HTTP Server and returns `IOStreams::Paths::HTTP`.

### Path Operations

Paths support common file operations, regardless of where the file is stored:

~~~ruby
path = IOStreams.path("sample/example.csv")

# Does the file exist?
path.exist?
# => true

# Size of the file in bytes.
path.size
# => 64

# Delete the file.
path.delete

# Move the file to another path, returning the target path.
path.move_to("sample/moved.csv")

# Create the directory path, when it does not already exist.
IOStreams.path("sample/data").mkpath
~~~

Inspect the components of a path's file name:

~~~ruby
# The last component of the path.
IOStreams.path("/home/gumby/work/ruby.rb").basename
# => "ruby.rb"

# Remove a specific suffix from the file name.
IOStreams.path("/home/gumby/work/ruby.rb").basename(".rb")
# => "ruby"

# Remove any extension by supplying ".*".
IOStreams.path("/home/gumby/work/ruby.rb").basename(".*")
# => "ruby"

# The directory portion of the path.
IOStreams.path("a/b/d/test.rb").dirname
# => "a/b/d"

# The extension, including the leading period.
IOStreams.path("a/b/d/test.rb").extname
# => ".rb"

# The extension, without the leading period.
IOStreams.path("a/b/d/test.rb").extension
# => "rb"
~~~

Notes:
* `basename`, `dirname`, `extname`, and `extension` return `nil` when no file name was set.
* A leading period on a dotfile is not treated as an extension, so `.profile` has no extension,
  while `.profile.sh` has the extension `sh`.
* A file name ending in a period, such as `foo.`, returns an empty string for the extension.

Iterate over the files in a path using a wildcard pattern:

~~~ruby
IOStreams.path("sample").each_child("*.csv") do |child|
  puts child
end

# Recursively, including sub-directories:
IOStreams.path("sample").each_child("**/*.csv") do |child|
  puts child
end
~~~

`each_child` is also available directly on `IOStreams` when the pattern includes the full path:

~~~ruby
IOStreams.each_child("sample/**/*.csv") { |child| puts child }
~~~

Notes:
* These operations are supported by File and S3 paths. SFTP supports `each_child`,
  and HTTP paths are read-only so they do not support any of them.
* By default `each_child` patterns are case-insensitive and hidden files are excluded.
  Supply `case_sensitive: true` or `hidden: true` to change this behavior.

### Using root paths

Roots allow paths to reference a particular root directory, so that all path names are appended to that root.
By using `IOStreams.join` instead of `IOStreams.path`, the storage location is no longer embedded in the
application code, it is configured once at startup.

The primary purpose of roots is to allow the exact same code to run in production and development,
yet use completely different data sources in each. For example, in production the root can point to an
S3 bucket, while in development it points to the local file system.

Roots are configured via an initializer at startup. Multiple roots can be setup, for example one for
input files, another for output files, another for reports, etc. During development the roots can all
point to a common location, while in production they could be completely different S3 buckets.

For example, inside an initializer:
~~~ruby
IOStreams.add_root(:default, "tmp/export")
IOStreams.add_root(:ftp, "tmp/ftp")
~~~

`:default` is used whenever a root is not supplied when calling `IOStreams.join`:
~~~ruby
# Uses the :default root: "tmp/export/sample/example.csv"
path = IOStreams.join("sample", "example.csv")

# Uses the :ftp root: "tmp/ftp/sample/example.csv"
path = IOStreams.join("sample", "example.csv", root: :ftp)
~~~

The following code:
~~~ruby
path = IOStreams.path("tmp/export", "sample", "example.csv")
path.writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

Can be reduced to:
~~~ruby 
path = IOStreams.join("sample", "example.csv")
path.writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

Most importantly the root path information and storage mechanism are externalized from the application code.

For example, to make the above code write to S3 in production, change the initializer to:
~~~ruby
IOStreams.add_root(:default, "s3://my-app-bucket-name/export")
IOStreams.add_root(:ftp, "s3://my-app-ftp-bucket-name/ftp")
~~~

The code calling `IOStreams.join` does not change at all, see [Config](config) for more examples.
