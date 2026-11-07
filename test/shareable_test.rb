# frozen_string_literal: true

require_relative "test_helper"

# The state of IOStreams that every Ractor can read: each test of the values runs in a process of its own, which loads
# every constant, see ShareableState.
class ShareableTest < Minitest::Test
  # The class-level methods that set the instance variables of their class or module, see ClassStateWriters: those that
  # configure IOStreams, and those that declare the fields of a contract, which an application calls as it starts, or as
  # it loads its classes, in the main Ractor, since no other Ractor can set them.
  CLASS_STATE_WRITERS = %w[
    IOStreams.add_allowed_path IOStreams.add_root IOStreams.delete_allowed_path IOStreams.deregister_extension
    IOStreams.logger= IOStreams.register_extension IOStreams.register_scheme IOStreams.temp_dir=
    IOStreams::Contract.descriptor= IOStreams::Contract.field IOStreams::Pgp.executable=
    IOStreams::Tabular.deregister_format IOStreams::Tabular.register_format
  ].freeze

  describe IOStreams do
    it "sets class-level state only in a method that configures it, or where IOStreams::Utils.main_ractor? is true" do
      require_relative "class_state_writers"
      writers = ClassStateWriters.find(Dir[File.expand_path("../lib/**/*.rb", __dir__)])

      assert_equal CLASS_STATE_WRITERS, writers,
                   "Remember a value of a class only if IOStreams::Utils.main_ractor?, or build it as the class is " \
                   "loaded, unless the method configures IOStreams, which CLASS_STATE_WRITERS then lists"
    end

    describe "in a process of its own" do
      before { skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor) }

      it "holds a shareable value in every constant" do
        script = <<~RUBY
          require "shareable_state"
          require "iostreams"
          require "xlsxtream"
          # test/query/shareable_test.rb checks IOStreams::Query, which needs Active Record.
          puts ShareableState.unshareable_constants(ShareableState.modules(IOStreams, except: ["IOStreams::Query"]))
        RUBY

        assert_equal [], run_script(script)
      end

      it "holds a shareable value in every instance variable of its classes, once each has remembered what it remembers" do
        script = <<~RUBY
          require "shareable_state"
          require "iostreams"
          require "xlsxtream"
          require "tmpdir"
          modules = ShareableState.modules(IOStreams, except: ["IOStreams::Query"])
          Dir.mktmpdir do |dir|
            schema = {fields: [{name: "at", type: "time"}]}
            IOStreams.path(dir, "a.json").schema(schema).writer(:hash) { |writer| writer << {"at" => "10:30:00"} }
            IOStreams.path(dir, "a.xlsx").schema(schema).writer(:hash) { |writer| writer << {"at" => "10:30:00"} }
            IOStreams.path(dir, "a.xlsx").each(:line) { |line| line }
            IOStreams.path(dir, "b.csv").copy_from(IOStreams.path(dir, "a.json"))
          end
          IOStreams::Utils.blank_text?(" ".encode("UTF-16LE"))
          IOStreams::Pgp.pgp_version
          IOStreams::Paths::S3::Sdk.unknown_options([:unknown])
          IOStreams.temp_dir
          puts ShareableState.unshareable_class_state(modules)
        RUBY

        assert_equal [], run_script(script)
      end
    end
  end
end
