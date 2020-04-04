# The miminum methods that any IOStreams Reader must implement.
class MinimalFileReader
  def self.open(file_name)
    io = new(file_name)
    yield(io)
  ensure
    io&.close
  end

  def initialize(file_name)
    @file = File.open(file_name)
  end

  def read(size = nil, outbuf = nil)
    @file.read(size, outbuf)
  end

  def close
    @file.close
  end

  def closed?
    @file.closed
  end
end
