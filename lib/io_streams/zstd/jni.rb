# frozen_string_literal: true

require "java"

module IOStreams
  module Zstd
    # Zstandard on JRuby with the `zstd-jni` jar, which the application adds to the classpath,
    # for example with jar-dependencies:
    #
    #   require_jar "com.github.luben", "zstd-jni", "1.5.7-3"
    module Jni
      BLOCK_SIZE = 65_536

      # Returns [Decoder] that decompresses the input stream.
      def self.decoder(input_stream)
        load_dependency
        Decoder.new(input_stream)
      end

      # Returns [Encoder] that writes the data compressed to the output stream.
      def self.encoder(output_stream, level: nil)
        load_dependency
        Encoder.new(output_stream, level: level)
      end

      def self.load_dependency
        Java::ComGithubLubenZstd::ZstdInputStream
      rescue NameError => e
        raise(LoadError,
              "Please add the zstd-jni jar to the classpath to support Zstandard on JRuby, for example with " \
              "jar-dependencies: require_jar(\"com.github.luben\", \"zstd-jni\", \"1.5.7-3\"). #{e.message}")
      end

      class Decoder
        def initialize(input_stream)
          @input  = InputStream.new(input_stream)
          @zstd   = Java::ComGithubLubenZstd::ZstdInputStreamNoFinalizer.new(@input)
          @buffer = Java::byte[BLOCK_SIZE].new
        end

        # Returns [String] the next block of decompressed data, or [nil] at the end of the stream.
        #
        # Raises [RuntimeError] for data that is not zstd, a frame cut short at the end of the input stream, or an input
        # stream without any data, like `zstd -d`.
        def read_block
          count = @zstd.read(@buffer, 0, BLOCK_SIZE)
          if count.negative?
            raise("zstd decompress error: the data is empty") unless @input.read?

            return
          end

          String.from_java_bytes(java.util.Arrays.copy_of_range(@buffer, 0, count))
        rescue java.io.IOException => e
          raise("zstd decompress error: #{e.message}")
        end

        # Frees the native decompression context, without closing the input stream, which belongs to the caller.
        def close
          @zstd.close
        end
      end

      # Uses the zstd-jni streams without a finalizer, since a finalizer would write the end of the frame
      # to the output stream whenever it ran, even after writing failed.
      #
      # Each frame ends with the checksum of its content, which reading checks, as the zstd command writes it.
      class Encoder
        def initialize(output_stream, level: nil)
          @output = AbortableOutput.new(output_stream)
          stream  = OutputStream.new(@output)
          @zstd   =
            if level.nil?
              Java::ComGithubLubenZstd::ZstdOutputStreamNoFinalizer.new(stream)
            else
              Java::ComGithubLubenZstd::ZstdOutputStreamNoFinalizer.new(stream, level)
            end
          @zstd.set_checksum(true)
        end

        def write(data)
          @zstd.write(data.to_java_bytes)
        end

        # Writes the end of the zstd frame, without closing the output stream, which belongs to the caller.
        def finish
          @zstd.close
        end

        # Frees the native compression context, discarding the data not yet written when writing did not finish,
        # so that the output stream does not receive an end of frame after the data written before the failure.
        def close
          @output.discard
          @zstd.close
        end
      end

      # A Java InputStream that reads from a Ruby IO.
      #
      # Closing it does not close the Ruby IO, which belongs to the caller.
      class InputStream < java.io.InputStream
        def initialize(io)
          super()
          @io   = io
          @read = false
        end

        # Returns [true|false] whether any data has been read from the IO.
        def read?
          @read
        end

        # Returns [Integer] the next byte, or the number of bytes read into `bytes`, or -1 at the end of the stream.
        def read(bytes = nil, offset = 0, length = bytes&.length)
          if bytes.nil?
            byte = @io.read(1)
            return -1 if byte.nil?

            @read = true
            return byte.getbyte(0)
          end
          return 0 if length.zero?

          data = @io.read(length)
          return -1 if data.nil?

          @read ||= !data.empty?
          data = data.to_java_bytes
          java.lang.System.arraycopy(data, 0, bytes, offset, data.length)
          data.length
        end
      end

      # A Java OutputStream that writes to a Ruby IO.
      #
      # Closing it does not close the Ruby IO, which belongs to the caller.
      class OutputStream < java.io.OutputStream
        def initialize(io)
          super()
          @io = io
        end

        def write(bytes, offset = 0, length = nil)
          if bytes.is_a?(Integer)
            @io.write((bytes & 0xff).chr)
          else
            length ||= bytes.length
            @io.write(String.from_java_bytes(java.util.Arrays.copy_of_range(bytes, offset, offset + length)))
          end
        end

        def close
        end
      end
    end
  end
end
