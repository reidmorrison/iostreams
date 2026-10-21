# frozen_string_literal: true

module IOStreams
  class Query
    # The Active Record type that casts each column of the result of a relation, as `pluck` chooses it, so that the rows
    # of a query are cast as `relation.pluck` casts them, see `IOStreams::Query::Columns#cast`.
    #
    # When each value that the relation selects is one column of its result, a column is cast by the first of:
    # - The attribute of Arel that the value is, or names as "table.column", such as `Customer.arel_table[:tier]` or
    #   "customers.tier": the attribute of the model of that table, see #table_type, otherwise the column of that table
    #   in the schema of the database, such as of a table joined with SQL.
    # - The attribute of the model of the relation of the same name.
    # - The attribute of the same name of a model that the relation joins by an association, see #joined_models, but
    #   not of a table joined with SQL.
    # - The type that the result gives the column, such as for a computed column, which only some databases give, such
    #   as PostgreSQL.
    # Otherwise, such as for no select, or `select("orders.*, customers.tier")`, whose one value is several columns, a
    # column is cast by the attribute of the model of the same name, otherwise by the type that the result gives it.
    #
    # It asks Active Record what its public API answers, apart from the type of a column of a table that no model of the
    # relation has, which `pluck` takes from the schema of the database, and the models of the joins of a relation of
    # another model that the relation merged, which Active Record holds in the joins of the relation.
    class CastTypes
      # A selected value that names a column of a table, such as "customers.tier", or "public.customers.tier", as Active
      # Record matches it.
      QUALIFIED = /\A(?<table>(?:\w+\.)?\w+)\.(?<column>\w+)\z/

      # Parameters:
      #   relation: [ActiveRecord::Relation]
      #     The relation whose results are cast.
      def initialize(relation)
        @relation = relation
        @model    = relation.klass
      end

      # Returns [Array<ActiveModel::Type::Value>] the type that casts each column of the result of the relation, in the
      # order of its columns, see above.
      #
      # Parameters:
      #   result: [ActiveRecord::Result]
      #     A result of the relation, such as of a query of no rows.
      def of(result)
        names  = result.columns
        values = @relation.select_values
        unless values.size == names.size
          return names.each_with_index.map { |name, index| @model.attribute_types.fetch(name) { result_type(result, index) } }
        end

        names.each_with_index.map do |name, index|
          selected_type(values[index]) ||
            @model.attribute_types.fetch(name) { joined_type(name) || result_type(result, index) }
        end
      end

      private

      # Returns [ActiveModel::Type::Value|nil] the type of the attribute of Arel that the selected value is, or names as
      # "table.column", see #table_type, otherwise nil, such as for a column of the model by its name, which is cast by
      # the attribute of that name, or the SQL of a computed column. An attribute of a table that has no types, such as
      # `Arel::Table.new(:customers)[:tier]`, is cast by its name too, for which `pluck` raises NoMethodError.
      def selected_type(value)
        case value
        when ::Arel::Attributes::Attribute
          value.type_caster if value.able_to_type_cast?
        when Symbol, String
          match = QUALIFIED.match(value.to_s)
          table_type(match[:table], match[:column]) if match
        end
      end

      # Returns [ActiveModel::Type::Value] the type of the column of the table: the attribute of the model of the table,
      # see #table_model, otherwise the type of the column in the schema of the database, as for a table joined with SQL,
      # or `ActiveModel::Type::Value`, which casts nothing, for a table or column that the schema does not have, such as
      # of a common table expression.
      def table_type(table, column)
        model = table_model(table)
        return model.type_for_attribute(column) if model

        ::ActiveRecord::TypeCaster::Connection.new(@model, table).type_for_attribute(column)
      end

      # Returns [Class|nil] the model of the table that a selected value names, as Active Record finds it: the model of
      # the association of the model of the relation named as the table, or as its singular, such as `belongs_to
      # :customer` for "customers", whether or not the relation joins it, unless the association is polymorphic,
      # otherwise the model of the relation for its own table, otherwise the first model of that table that it joins.
      def table_model(table)
        reflection = @model.reflect_on_association(table) || @model.reflect_on_association(table.singularize)
        return (reflection.klass unless reflection.polymorphic?) if reflection
        return @model if table == @model.table_name

        joined_models.find { |model| model.table_name == table }
      end

      # Returns [ActiveModel::Type::Value|nil] the type of the attribute of the name of the first model that the relation
      # joins that has one, see #joined_models.
      def joined_type(name)
        joined_models.each do |model|
          type = model.attribute_types.fetch(name, nil)
          return type if type
        end
        nil
      end

      # Returns [Array<Class>] the models that the relation joins by their associations, in the order that `pluck` looks
      # for an attribute in them: each association of `joins` and `left_joins`, followed by those joined within it, such
      # as `joins(customer: :region)`, then the joins of a relation of another model that the relation merged, such as
      # `merge(Customer.joins(:region))`. A table joined with SQL, or a common table expression, has no model.
      def joined_models
        @joined_models ||= begin
          tree   = {}
          merged = []
          (@relation.joins_values | @relation.left_outer_joins_values).each do |join|
            case join
            when Symbol then add_join(tree, join) unless common_table?(join)
            when Hash, Array then add_join(tree, join)
            when ::ActiveRecord::Associations::JoinDependency then merged << join
            end
          end
          models = associated_models(@model, tree)
          merged.each { |dependency| dependency.each { |join| models << join.base_klass } }
          models
        end
      end

      # Adds the names of the associations of a join to the tree of them, as Active Record does: a name, an Array of
      # them, or a Hash of names to the associations joined within each.
      def add_join(tree, associations)
        case associations
        when Symbol, String
          tree[associations.to_sym] ||= {}
        when Array
          associations.each { |association| add_join(tree, association) }
        when Hash
          associations.each do |name, nested|
            branch = tree[name] ||= {}
            add_join(branch, nested) if nested
          end
        end
      end

      # Returns [Array<Class>] the models of the associations of the tree, each followed by those of the associations
      # within it.
      def associated_models(model, tree, models = [])
        tree.each do |name, nested|
          reflection = model.reflect_on_association(name)
          # Which Active Record would have raised for when it built the query.
          next if reflection.nil? || reflection.polymorphic?

          models << reflection.klass
          associated_models(reflection.klass, nested, models)
        end
        models
      end

      # Returns [true|false] whether the join names a common table expression of the relation, see `with`.
      def common_table?(join)
        @relation.with_values.any? { |with| with.key?(join) }
      end

      # Returns [ActiveModel::Type::Value] the type that the result gives the column at the index, or
      # `ActiveModel::Type::Value`, which casts nothing, when it gives none.
      def result_type(result, index)
        result.column_types[index] || ::ActiveRecord::Type.default_value
      end
    end
  end
end
