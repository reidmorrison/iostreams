# frozen_string_literal: true

require_relative "test_helper"

class AbortableOutputTest < Minitest::Test
  describe IOStreams::AbortableOutput do
    let(:output) { StringIO.new(+"") }
    let(:abortable) { IOStreams::AbortableOutput.new(output) }

    # Writes "x" in each way that an IO writes, other than #write and #pwrite, which StringIO lacks.
    def write_each_way(io)
      io << "<<"
      io.print("print")
      io.puts("puts")
      io.printf("%s", "printf")
      io.putc("p")
      io.syswrite("syswrite")
      io.write_nonblock("write_nonblock")
    end

    it "passes on what is written, in each way that an IO writes" do
      assert_equal 5, abortable.write("write")
      assert_same abortable, abortable << ""
      write_each_way(abortable)

      assert_equal "write<<printputs\nprintfpsyswritewrite_nonblock", output.string
    end

    it "discards what is written once discard is called, in each way that an IO writes" do
      abortable.write("kept")
      abortable.discard

      assert_equal 5, abortable.write("write")
      assert_equal 6, abortable.pwrite("pwrite", 0)
      assert_equal 8, abortable.syswrite("syswrite")
      assert_equal 14, abortable.write_nonblock("write_nonblock")
      assert_equal "p", abortable.putc("p")
      write_each_way(abortable)
      abortable.flush

      assert_equal "kept", output.string
    end

    it "passes every other request on to the output stream, apart from binmode" do
      Tempfile.create("abortable") do |file|
        abortable = IOStreams::AbortableOutput.new(file)

        assert_equal file.path, abortable.path
        assert_same abortable, abortable.binmode
        refute_predicate file, :binmode?
        abortable.close

        assert_predicate file, :closed?
      end
      refute_respond_to IOStreams::AbortableOutput.new(StringIO.new(+"")), :path
    end
  end
end
