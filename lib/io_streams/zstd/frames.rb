# frozen_string_literal: true

module IOStreams
  module Zstd
    # Follows the frames of zstd data as it is read, without decompressing it, so that a decoder can tell whether the
    # data ended within a frame, which `zstd-ruby` does not report, nor zstd-jni for a frame cut off before its checksum,
    # see the Zstandard format, RFC 8878.
    #
    # Reads only the header of each frame and the 3 byte header of each of its blocks, and skips the content of each
    # block, so that it costs a few operations for each block of upto 128KB. It stops following data that is not zstd,
    # such as an unknown magic number, which the decoder reports itself.
    #
    # Used internally by the decoder of each zstd library, see `IOStreams::Zstd::Native` and `IOStreams::Zstd::Jni`.
    class Frames
      # The magic number that starts a frame of zstd data.
      MAGIC = 0xFD2FB528

      # The magic numbers that start a skippable frame, 0x184D2A50 to 0x184D2A5F, and the mask that matches them.
      SKIPPABLE_MAGIC = 0x184D2A50
      SKIPPABLE_MASK  = 0xFFFFFFF0

      # The type of a block whose content is the one byte that it repeats.
      RLE_BLOCK = 1

      # The type of block that is reserved, which is not zstd.
      RESERVED_BLOCK = 3

      def initialize
        expect(:magic, 4)
      end

      # Returns [true|false] whether the data so far ends at the end of a frame, or is not zstd, since the decoder
      # reports data that is not zstd itself.
      def complete?
        @part == :unknown || (@part == :magic && @field.empty? && @skip.zero?)
      end

      # Follows the frames through the supplied data, which continues the data supplied before it.
      def <<(data)
        offset = 0
        while offset < data.bytesize && @part != :unknown
          if @skip.positive?
            length = [@skip, data.bytesize - offset].min
            @skip -= length
          else
            length = [@length - @field.bytesize, data.bytesize - offset].min
            @field << data.byteslice(offset, length)
            read_field if @field.bytesize == @length
          end
          offset += length
        end
        self
      end

      private

      # Expects the supplied part of the data next, the field of the supplied length, once the supplied number of bytes
      # of content has been skipped.
      def expect(part, length, skip = 0)
        @part   = part
        @length = length
        @skip   = skip
        @field  = String.new(encoding: Encoding::BINARY)
      end

      # Reads the field that is complete, and expects the part of the data that follows it.
      def read_field
        case @part
        when :magic
          read_magic(@field.unpack1("V"))
        when :skippable_size
          expect(:magic, 4, @field.unpack1("V"))
        when :frame_header
          read_frame_header(@field.getbyte(0))
        when :block_header
          read_block_header(@field.getbyte(0) | (@field.getbyte(1) << 8) | (@field.getbyte(2) << 16))
        end
      end

      def read_magic(magic)
        if magic == MAGIC
          expect(:frame_header, 1)
        elsif (magic & SKIPPABLE_MASK) == SKIPPABLE_MAGIC
          expect(:skippable_size, 4)
        else
          expect(:unknown, 0)
        end
      end

      # The frame header descriptor gives the size of the rest of the frame header, which is skipped: the window
      # descriptor, unless the frame is a single segment, the dictionary id, and the frame content size.
      def read_frame_header(descriptor)
        single    = descriptor.anybits?(0x20)
        @checksum = descriptor.anybits?(0x04)
        size      = (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 0x03] + [single ? 1 : 0, 2, 4, 8][descriptor >> 6]
        expect(:block_header, 3, size)
      end

      # The block header gives whether it is the last block of the frame, its type, and its size, which is skipped,
      # followed by the checksum of the frame after its last block, when it has one.
      def read_block_header(header)
        type = (header >> 1) & 0x03
        return expect(:unknown, 0) if type == RESERVED_BLOCK

        size = type == RLE_BLOCK ? 1 : header >> 3
        if header.nobits?(0x01)
          expect(:block_header, 3, size)
        else
          expect(:magic, 4, @checksum ? size + 4 : size)
        end
      end
    end
  end
end
