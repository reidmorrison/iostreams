---
layout: default
---

# Path

A path describes the data store and the attributes for the file to be stored there.
In order to apply a streaming pipeline it needs to know where the data is being stored and how it should be accessed.

When a path is created it takes the name of the file which can also be a URI, followed by several arguments
specific to that path. IOStreams will infer the file storage mechanism based on the supplied URI.



IOStreams Path already supports accessing files in the following places:

* File
* AWS S3
* SFTP
* HTTP(S) (Read only)

Are you using another cloud provider and want to add support for your favorite?
Checkout the supplied [IOStreams S3 path provider](https://github.com/reidmorrison/iostreams/blob/master/lib/io_streams/paths/s3.rb)
for an example of what is required. 

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

Read a file from a remote sftp server.
~~~ruby
IOStreams.path("sftp://example.org/path/file.txt", 
               username: "jbloggs", 
               password: "secret", 
               compression: false).
  reader do |input|
    puts input.read
  end
~~~

Raises Net::SFTP::StatusException when the file could not be read.

Write to a file on a remote sftp server.
~~~ruby
IOStreams.path("sftp://example.org/path/file.txt", 
               username: "jbloggs", 
               password: "secret", 
               compression: false).
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
                      ssh_options: {IdentityFile: "~/.ssh/private_key"}).
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

**ssh_options
  Any other options supported by ssh_config.
  `man ssh_config` to see all available options.

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

* http_redirect_count: [Integer]

  Maximum number of http redirects to follow.

~~~ruby 
path = IOStreams.path("http://hostname/path/example.csv")
~~~

Similarly when using https:

~~~ruby 
path = IOStreams.path("https://hostname/path/example.csv")
~~~

This time IOStreams inferred that the file lives on an HTTP Server and returns `IOStreams::Paths::HTTP`.

### Using root paths

If root paths have been setup, see [Config](config) to add root paths, then `IOStreams.join` can be used instead
of `IOStreams.path`. 

The key difference is that `IOStreams.join` joins the supplied path(s) with the default or named root path so that
the entire path does not need to be supplied.

Set the default root path in an initializer.
~~~ruby
IOStreams.add_root(:default, "/var/my_app/files")
~~~

The following code:
~~~ruby
path = IOStreams.path("/var/my_app/files", "sample", "example.csv", root: :uploads)
path.writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

Can be reduced to:
~~~ruby 
path = IOStreams.join("sample", "example.csv", root: :uploads)
path.writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

Most importantly the root path information and storage mechanism are externalized from the application code.

For example, to make the above code write to S3, change the initializer to:
~~~ruby
IOStreams.add_root(:default, "s3://my-app-bucket-name/files")
~~~
