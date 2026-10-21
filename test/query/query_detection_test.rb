# frozen_string_literal: true

require_relative "query_helper"
require "open3"
require "rbconfig"

# How `IOStreams.stream` tells an Active Record query from an IO, see `IOStreams::Query.query?`, which it asks of every
# IO, in a process that has only required Active Record, as an application does before it first uses a query.
class QueryDetectionTest < Minitest::Test
  describe "IOStreams::Query.query?" do
    # The query helper has already loaded the classes of Active Record, so each check runs in a new process that has
    # only required it, whose classes, such as `ActiveRecord::Relation`, are autoloaded when they are first used.
    # Returns [String] the output of the process.
    def run_with_active_record(code)
      script = <<~RUBY
        require "iostreams"
        require "stringio"
        require "active_record"
        #{code}
      RUBY
      output, = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
      output
    end

    it "does not load the classes of Active Record that it has not loaded yet, to stream an IO" do
      code = <<~RUBY
        IOStreams.stream(StringIO.new("a")).read
        print ActiveRecord.autoload?(:Relation) && ActiveRecord.autoload?(:Batches) ? "not loaded" : "loaded"
      RUBY

      assert_equal "not loaded", run_with_active_record(code)
    end

    # The batches of a relation need a connection to the database on Active Record 7.2, which this process does not
    # have, so the tests of IOStreams::Query::Stream show that they are read too.
    it "tells a relation from an IO, once Active Record has loaded its class" do
      code = <<~RUBY
        IOStreams.stream(StringIO.new("a"))
        model = Class.new(ActiveRecord::Base) { self.table_name = "orders" }
        print [model.all, StringIO.new].map { |io| IOStreams.stream(io).class.name }.join(" ")
      RUBY

      assert_equal "IOStreams::Query::Stream IOStreams::Stream", run_with_active_record(code)
    end
  end
end
