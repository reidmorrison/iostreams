# frozen_string_literal: true

require_relative "query_helper"

# The slices of the rows of an Active Record query, see `IOStreams::Query::Stream`, stored and read elsewhere, as
# Rocket Job's workers read the slices that a job uploads, on each database of QueryDatabase.
class QuerySlicesTest < Minitest::Test
  QueryDatabase.each do |database|
    describe "the slices of #{IOStreams::Query::Stream.name} on #{database.name}" do
      let(:db) { database }
      let(:relation) { db.order.order(:id).select(:shipped_on, :weight) }
      let(:schema) { IOStreams.stream(relation).schema }
      # The second order has neither a date shipped nor a weight, so every value of its row is null.
      let(:expected) do
        [{"shipped_on" => Date.new(2026, 10, 1), "weight" => 1.5}, {"shipped_on" => nil, "weight" => nil},
         {"shipped_on" => Date.new(1969, 12, 31), "weight" => nil}]
      end

      before { db.load }

      # Returns [Array<Hash>] the slices of the query, each stored as JSON and turned back from its Hash.
      def stored_slices(size: 2)
        list = []
        IOStreams.stream(relation).each(:slice, size: size) { |slice| list << JSON.generate(slice.to_h) }
        list.map { |json| IOStreams.slice(JSON.parse(json)) }
      end

      def each(stream, mode = :hash, **)
        list = []
        stream.each(mode, **) { |row| list << row }
        list
      end

      it "holds that each row is a record, so that a row whose every value is null is read as one where it is stored" do
        slices = stored_slices

        assert_equal [false, false], slices.map(&:blank_rows?)
        assert_equal [1, 3], slices.map(&:record_number)
        assert_equal [nil, nil], slices.map(&:line_number)
        assert_equal(expected, slices.flat_map { |slice| each(IOStreams.stream(slice).schema(schema)) })
        assert_equal(expected, slices.flat_map { |slice| each(IOStreams.stream(slice).schema(schema), :hash, skip_blanks: true) })
      end

      it "holds that the values of its rows are those of the fields of the columns, which Active Record cast" do
        slices = stored_slices

        assert_equal [true, true], slices.map(&:typed?)
        assert_equal(expected, slices.flat_map { |slice| each(IOStreams.stream(slice).schema(schema)) })
      end

      it "holds that the values are not typed by a schema that was set, which converts them where they are read" do
        own    = {"fields" => [{"name" => "shipped_on", "type" => "string"}, {"name" => "weight", "type" => "string"}]}
        slices = []
        IOStreams.stream(relation).schema(own).each(:slice, size: 5) { |slice| slices << slice }

        assert_equal [false], slices.map(&:typed?)
      end

      it "resumes the slices and records of the query at a record, as a job that resumes them reads them" do
        slices = []
        IOStreams.stream(relation).each(:slice, size: 5, resume_at: 2) { |slice| slices << slice }

        assert_equal([[2, 3]], slices.map { |slice| [slice.record_number, slice.record_number_at(-1)] })
        assert_equal expected.drop(1), each(IOStreams.stream(relation), :hash, resume_at: 2)
      end

      it "copies the records to a store of slices as lines of CSV, by the schema of the query" do
        store = Class.new do
          include IOStreams::Slice::Target

          attr_reader :slices

          def slice_size
            2
          end

          def write_slice(slice)
            (@slices ||= []) << slice
          end
        end.new
        IOStreams.stream(store).copy_from(relation, mode: :hash)

        assert_equal [%w[shipped_on weight], %w[shipped_on weight]], store.slices.map(&:header)
        assert_equal [["2026-10-01,1.5", ","], ["1969-12-31,"]], store.slices.map(&:rows)
        # The rows of a query are not lines of a file, so each row holds its record number, and no line.
        assert_equal [1, 3], store.slices.map(&:record_number)
        assert_equal [nil, nil], store.slices.map(&:line_number)
        # A row of nulls is a line of only commas, which each slice holds is a record, as each(:slice) of the query does.
        assert_equal [false, false], store.slices.map(&:blank_rows?)
        assert_equal(expected, store.slices.flat_map { |slice| each(IOStreams.stream(slice).schema(schema)) })
        assert_equal(expected, store.slices.flat_map { |slice| each(IOStreams.stream(slice).schema(schema), :hash, skip_blanks: true) })
      end

      it "writes its slices to a file, by the schema of the query, keeping a row whose every value is null" do
        output = StringIO.new
        IOStreams.stream(output).format(:json).schema(schema).writer(:slice) do |io|
          stored_slices.each { |slice| io << slice }
        end

        assert_equal %({"shipped_on":"2026-10-01","weight":1.5}\n{"shipped_on":null,"weight":null}\n) +
                     %({"shipped_on":"1969-12-31","weight":null}\n), output.string
      end

      it "holds blank_rows: false and typed: true in the Hash of each slice" do
        hashes = []
        IOStreams.stream(relation).each(:slice, size: 5) { |slice| hashes << slice.to_h }

        assert_equal [%w[rows header format blank_rows typed record_number]], hashes.map(&:keys)
        refute hashes.first["blank_rows"]
        assert hashes.first["typed"]
      end

      it "is written as JSON by ActiveSupport, which applies the options of as_json to it as to a Hash" do
        slices = []
        IOStreams.stream(relation).each(:slice, size: 5) { |slice| slices << slice }
        slice = slices.first

        assert_equal slice.to_h.as_json, slice.as_json
        assert_equal({"rows" => slice.to_h["rows"].as_json}, slice.as_json(only: "rows"))
        assert_equal %w[rows format blank_rows typed record_number], slice.as_json(except: "header").keys
      end

      it "copies a row whose every value is null from the slice that holds it" do
        output = StringIO.new
        IOStreams.stream(output).format(:json).copy_from(IOStreams.stream(stored_slices.first).schema(schema), mode: :hash)

        assert_equal %({"shipped_on":"2026-10-01","weight":1.5}\n{"shipped_on":null,"weight":null}\n), output.string
      end

      it "reads a row whose every value is empty text, or null, as a record too" do
        relation = db.order.order(:id).select("'' AS note", "NULL AS other")
        list     = []
        IOStreams.stream(relation).each(:slice, size: 5) { |slice| list << IOStreams.slice(JSON.parse(JSON.generate(slice.to_h))) }

        assert_equal [{"note" => "", "other" => nil}] * 3, each(IOStreams.stream(list.first), :hash, skip_blanks: true)
      end
    end
  end
end
