defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  require Logger

  defmacro __using__(opts \\ []) do
    Code.compiler_options(ignore_module_conflict: true)

    repo = opts[:repo]

    unless repo do
      raise "Please specify a repo module when using Graphism"
    end

    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :repo,
      accumulate: false,
      persist: true
    )

    Module.put_attribute(__CALLER__.module, :repo, opts[:repo])

    alias Dataloader, as: DL

    quote do
      defmodule Dataloader.Repo do
        def data do
          DL.Ecto.new(unquote(repo), query: &query/2)
        end

        def query(queryable, _params) do
          queryable
        end
      end

      import unquote(__MODULE__), only: :macros
      @before_compile unquote(__MODULE__)

      use Absinthe.Schema
      import Absinthe.Resolution.Helpers, only: [dataloader: 1]

      @sources [unquote(__CALLER__.module).Dataloader.Repo]

      def context(ctx) do
        loader =
          Enum.reduce(@sources, DL.new(), fn source, loader ->
            DL.add_source(loader, source, source.data())
          end)

        Map.put(ctx, :loader, loader)
      end

      def plugins do
        [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
      end

      def middleware(middleware, _field, object) do
        middleware ++ [Graphism.ErrorMiddleware]
      end
    end
  end

  defmacro __before_compile__(_) do
    schema =
      __CALLER__.module
      |> Module.get_attribute(:schema)
      |> resolve()

    repo =
      __CALLER__.module
      |> Module.get_attribute(:repo)

    unless length(schema) > 0 do
      raise """
        Your Graphism schema is empty. Please define at least
        one entity:

        entity :my_entity do
          attribute :id, :id
          attribute :name, :string
        end
      """
    end

    schema_fun =
      quote do
        def schema do
          unquote(schema)
        end
      end

    schema =
      schema
      |> Enum.reverse()

    schema
    |> Enum.each(fn e ->
      if Enum.empty?(e[:attributes]) and
           Enum.empty?(e[:relations]) do
        raise "Entity #{e[:name]} is empty"
      end
    end)

    schema_empty_modules =
      schema
      |> Enum.reject(&virtual?(&1))
      |> Enum.map(fn e ->
        schema_empty_module(e, schema, caller: __CALLER__)
      end)

    schema_modules =
      schema
      |> Enum.reject(&virtual?(&1))
      |> Enum.map(fn e ->
        schema_module(e, schema, caller: __CALLER__)
      end)

    api_modules =
      Enum.map(schema, fn e ->
        api_module(e, schema, repo: repo, caller: __CALLER__)
      end)

    resolver_modules =
      Enum.map(schema, fn e ->
        resolver_module(e, schema, caller: __CALLER__)
      end)

    enums =
      Enum.map(schema, fn e ->
        graphql_enum(e, schema)
      end)

    objects =
      Enum.map(schema, fn e ->
        graphql_object(e, schema, caller: __CALLER__.module)
      end)

    self_resolver =
      quote do
        defmodule Resolver.Self do
          def itself(parent, _, _) do
            {:ok, parent}
          end
        end
      end

    entities_queries =
      Enum.flat_map(schema, fn e ->
        [single_graphql_queries(e, schema), multiple_graphql_queries(e, schema)]
      end)
      |> Enum.reject(fn queries -> queries == nil end)

    queries =
      quote do
        query do
          (unquote_splicing(
             schema
             |> Enum.reject(&internal?(&1))
             |> Enum.flat_map(fn e ->
               [
                 if_entity_action(e, :read, fn ->
                   quote do
                     field unquote(String.to_atom("#{e[:plural]}")),
                           non_null(unquote(String.to_atom("#{e[:plural]}_queries"))) do
                       resolve(&Resolver.Self.itself/3)
                     end
                   end
                 end),
                 if_entity_action(e, :list, fn ->
                   quote do
                     field unquote(String.to_atom("#{e[:name]}")),
                           non_null(unquote(String.to_atom("#{e[:name]}_queries"))) do
                       resolve(&Resolver.Self.itself/3)
                     end
                   end
                 end)
               ]
             end)
             |> without_nils()
           ))
        end
      end

    entities_mutations =
      schema
      |> Enum.reject(&internal?(&1))
      |> Enum.map(fn e ->
        graphql_mutations(e, schema)
      end)

    mutations =
      quote do
        mutation do
          (unquote_splicing(
             schema
             |> Enum.reject(&internal?(&1))
             |> Enum.map(fn e ->
               quote do
                 field unquote(String.to_atom("#{e[:name]}")),
                       non_null(unquote(String.to_atom("#{e[:name]}_mutations"))) do
                   resolve(&Resolver.Self.itself/3)
                 end
               end
             end)
           ))
        end
      end

    List.flatten([
      schema_fun,
      schema_empty_modules,
      schema_modules,
      api_modules,
      resolver_modules,
      enums,
      objects,
      self_resolver,
      entities_queries,
      queries,
      entities_mutations,
      mutations
    ])
  end

  defmacro entity(name, opts \\ [], do: block) do
    caller_module = __CALLER__.module

    attrs = attributes_from(block)
    rels = relations_from(block)
    actions = actions_from(block)

    entity =
      [name: name, attributes: attrs, relations: rels, enums: [], opts: opts, actions: actions]
      |> with_plural()
      |> with_table_name()
      |> with_schema_module(caller_module)
      |> with_api_module(caller_module)
      |> with_resolver_module(caller_module)
      |> with_enums()
      |> with_supported_actions()
      |> check_actions!()

    Module.put_attribute(__CALLER__.module, :schema, entity)

    block
  end

  defmacro attribute(name, type, opts \\ []) do
    validate_attribute_name!(name)
    validate_attribute_type!(type)
    validate_attribute_opts!(opts)
  end

  defmacro has_many(_name, _opts \\ []) do
  end

  defmacro has_one(_name, _opts \\ []) do
  end

  defmacro belongs_to(_name, _opts \\ []) do
  end

  defmacro create(_opts) do
  end

  defp without_nils(enum) do
    Enum.reject(enum, fn item -> item == nil end)
  end

  defp validate_attribute_name!(name) do
    unless is_atom(name) do
      raise "Attribute #{name} should be an atom"
    end
  end

  @supported_attribute_types [
    :id,
    :string,
    :integer,
    :number,
    :date,
    :boolean
  ]

  defp validate_attribute_type!(type) do
    unless Enum.member?(@supported_attribute_types, type) do
      raise "Unsupported attribute type #{inspect(type)}. Must be one of #{
              inspect(@supported_attribute_types)
            }"
    end
  end

  defp validate_attribute_opts!(opts) do
    unless is_list(opts) do
      raise "Unsupported attribute opts #{inspect(opts)}. Must be a keyword list"
    end
  end

  defp with_plural(entity) do
    case entity[:plural] do
      nil ->
        plural = Inflex.pluralize("#{entity[:name]}")
        Keyword.put(entity, :plural, String.to_atom(plural))

      _ ->
        entity
    end
  end

  defp with_table_name(entity) do
    table_name =
      entity[:plural]
      |> Atom.to_string()
      |> Inflex.parameterize("_")
      |> String.to_atom()

    Keyword.put(entity, :table, table_name)
  end

  defp with_schema_module(entity, caller_mod) do
    module_name(caller_mod, entity, :schema_module)
  end

  defp with_resolver_module(entity, caller_mod) do
    module_name(caller_mod, entity, :resolver_module, :resolver)
  end

  defp with_api_module(entity, caller_mod) do
    module_name(caller_mod, entity, :api_module, :api)
  end

  defp module_name(prefix, entity, name, suffix \\ nil) do
    module_name =
      [prefix, entity[:name], suffix]
      |> Enum.reject(fn part -> part == nil end)
      |> Enum.map(&Atom.to_string(&1))
      |> Enum.map(&Inflex.camelize(&1))
      |> Module.concat()

    Keyword.put(
      entity,
      name,
      module_name
    )
  end

  # Inspect attributes and extract enum types from those attributes
  # that have a defined set of possible values
  defp with_enums(entity) do
    enums =
      entity[:attributes]
      |> Enum.filter(fn attr -> attr[:opts][:one_of] end)
      |> Enum.reduce([], fn attr, enums ->
        enum_name = enum_name(entity, attr)
        values = attr[:opts][:one_of]
        [[name: enum_name, values: values] | enums]
      end)

    Keyword.put(entity, :enums, enums)
  end

  defp enum_name(e, attr) do
    String.to_atom("#{e[:name]}_#{attr[:name]}s")
  end

  @default_entity_actions [:read, :list, :create, :update, :delete]

  defp with_supported_actions(e) do
    actions = e[:opts][:actions] || @default_entity_actions
    put_in(e, [:opts, :actions], actions)
  end

  defp check_actions!(e) do
    if virtual?(e) do
      e[:opts][:actions]
      |> Enum.each(fn a ->
        action_spec = e[:actions][a]

        unless action_spec && action_spec[:produces] && action_spec[:using] do
          raise "entity #{e[:name]} is virtual but does not define a spec for action #{a}"
        end
      end)
    end

    e
  end

  defp if_entity_action(e, action, next) do
    case action?(e, action) do
      true ->
        next.()

      false ->
        nil
    end
  end

  defp virtual?(entity) do
    Enum.member?(entity[:opts][:modifiers] || [], :virtual)
  end

  defp internal?(entity) do
    Enum.member?(entity[:opts][:modifiers] || [], :internal)
  end

  defp secret?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :secret)
  end

  # Resolves the given schema, by inspecting links between entities
  # and making sure everything is consistent
  defp resolve(schema) do
    # Index plurals so that we can later resolve relations
    plurals =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:plural], e[:name])
      end)

    # Index entities by name
    index =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:name], e)
      end)

    schema
    |> Enum.map(fn e ->
      e
      |> with_display_name()
      |> with_relations!(index, plurals)
    end)
  end

  def with_display_name(e) do
    display_name = display_name(e[:name])

    plural_display_name = display_name(e[:plural])

    e
    |> Keyword.put(:display_name, display_name)
    |> Keyword.put(:plural_display_name, plural_display_name)
  end

  defp display_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> Inflex.camelize()
    |> :string.titlecase()
  end

  # Ensure all relations are properly formed.
  # This function will raise an error if the target entity
  # for a relation cannot be found
  defp with_relations!(e, index, plurals) do
    relations =
      e[:relations]
      |> Enum.map(fn rel ->
        case rel[:kind] do
          :has_many ->
            target = plurals[rel[:name]]

            unless target do
              raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{
                      inspect(plurals)
                    }"
            end

            rel
            |> Keyword.put(:target, target)
            |> Keyword.put(:name, rel[:opts][:as] || rel[:name])

          _ ->
            target = index[rel[:name]]

            unless target do
              raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{
                      inspect(Map.keys(index))
                    }"
            end

            rel
            |> Keyword.put(:target, target[:name])
            |> Keyword.put(:name, rel[:opts][:as] || rel[:name])
        end
      end)

    Keyword.put(e, :relations, relations)
  end

  defp schema_empty_module(e, _schema, _opts) do
    quote do
      defmodule unquote(e[:schema_module]) do
      end
    end
  end

  defp schema_module(e, schema, _opts) do
    quote do
      defmodule unquote(e[:schema_module]) do
        use Ecto.Schema
        import Ecto.Changeset

        unquote_splicing(
          # alias all modules referenced by has_many
          # relations

          e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
          |> Enum.map(fn rel ->
            target = find_entity!(schema, rel[:target])
            schema_module = target[:schema_module]

            quote do
              alias unquote(schema_module)
            end
          end)
        )

        @primary_key {:id, :binary_id, autogenerate: false}

        schema unquote("#{e[:plural]}") do
          unquote_splicing(
            e[:attributes]
            |> Enum.reject(fn attr -> attr[:name] == :id end)
            |> Enum.map(fn attr ->
              quote do
                Ecto.Schema.field(unquote(attr[:name]), unquote(attr[:kind]))
              end
            end)
          )

          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              target = find_entity!(schema, rel[:target])

              quote do
                Ecto.Schema.belongs_to(unquote(rel[:name]), unquote(target[:schema_module]),
                  type: :binary_id
                )
              end
            end)
          )

          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
            |> Enum.map(fn rel ->
              target = find_entity!(schema, rel[:target])
              schema_module = target[:schema_module]

              quote do
                Ecto.Schema.has_many(unquote(rel[:name]), unquote(schema_module))
              end
            end)
          )

          timestamps()
        end

        @required_fields unquote(
                           (e[:attributes]
                            |> Enum.reject(&readonly?(&1))
                            |> Enum.reject(&optional?(&1))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e[:relations]
                              |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        @optional_fields unquote(
                           (e[:attributes]
                            |> Enum.filter(&optional?(&1))
                            |> Enum.map(fn attr ->
                              attr[:name]
                            end)) ++
                             (e[:relations]
                              |> Enum.filter(fn rel -> rel[:kind] == :has_one end)
                              |> Enum.map(fn rel ->
                                String.to_atom("#{rel[:name]}_id")
                              end))
                         )

        def changeset(e, attrs) do
          changes =
            e
            |> cast(attrs, @required_fields)
            |> cast(attrs, @optional_fields)
            |> validate_required(@required_fields)
            |> unique_constraint(:id, name: unquote("#{e[:table]}_pkey"))

          unquote_splicing(
            e[:attributes]
            |> Enum.filter(fn attr -> attr[:opts][:unique] end)
            |> Enum.map(fn attr ->
              quote do
                changes =
                  changes
                  |> unique_constraint(
                    unquote(attr[:name]),
                    name: unquote("unique_#{attr[:name]}_per_#{e[:table]}")
                  )
              end
            end)
          )
        end
      end
    end
  end

  defp with_entity_funs(funs, e, action, fun) do
    case action?(e, action) do
      true ->
        case fun.() do
          [_ | _] = more_funs ->
            more_funs ++ [funs]

          single_fun ->
            [single_fun | funs]
        end

      false ->
        funs
    end
  end

  defp with_resolver_read_funs(funs, e, _schema, api_module) do
    with_entity_funs(funs, e, :read, fn ->
      [
        quote do
          def get_by_id(_, %{id: id}, _) do
            unquote(api_module).get_by_id(id)
          end
        end
        | e[:attributes]
          |> Enum.filter(fn attr -> attr[:opts][:unique] end)
          |> Enum.map(fn attr ->
            quote do
              def unquote(String.to_atom("get_by_#{attr[:name]}"))(
                    _,
                    %{unquote(attr[:name]) => arg},
                    _
                  ) do
                unquote(api_module).unquote(String.to_atom("get_by_#{attr[:name]}"))(arg)
              end
            end
          end)
      ]
    end)
  end

  defp with_resolver_list_funs(funs, e, _schema, api_module) do
    with_entity_funs(funs, e, :list, fn ->
      [
        quote do
          def list_all(_, _, _) do
            {:ok, unquote(api_module).list()}
          end
        end
        | e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
          |> Enum.map(fn rel ->
            quote do
              def unquote(String.to_atom("list_by_#{rel[:name]}"))(
                    _,
                    %{unquote(rel[:name]) => arg},
                    _
                  ) do
                {:ok, unquote(api_module).unquote(String.to_atom("list_by_#{rel[:name]}"))(arg)}
              end
            end
          end)
      ]
    end)
  end

  defp resolver_arg_transforms_block(e) do
    case Enum.filter(e[:attributes], fn attr ->
           attr[:opts][:transform]
         end) do
      [] ->
        quote do
        end

      attrs ->
        quote do
          args =
            with unquote_splicing(
                   attrs
                   |> Enum.map(fn attr ->
                     quote do
                       {:ok, args} <-
                         transform_arg(
                           args,
                           unquote(attr[:name]),
                           unquote(attr[:opts][:transform])
                         )
                     end
                   end)
                 ) do
              args
            end
        end
    end
  end

  defp with_resolver_create_fun(funs, e, schema, api_module) do
    with_entity_funs(funs, e, :create, fn ->
      quote do
        def create(_, args, _) do
          unquote(resolver_arg_transforms_block(e))

          unquote(
            case Enum.filter(e[:relations], fn rel -> rel[:kind] == :belongs_to end) do
              [] ->
                quote do
                  # Generate an id for the new resource
                  args
                  |> Map.put(:id, Ecto.UUID.generate())
                  |> unquote(api_module).create()
                end

              rels ->
                quote do
                  with unquote_splicing(
                         rels
                         |> Enum.map(fn rel ->
                           parent_var = Macro.var(rel[:name], nil)
                           target = find_entity!(schema, rel[:target])

                           quote do
                             {:ok, unquote(parent_var)} <-
                               unquote(target[:api_module]).get_by_id(args.unquote(rel[:name]))
                           end
                         end)
                       ) do
                    args =
                      args
                      |> Map.drop(unquote(Enum.map(rels, fn rel -> rel[:name] end)))
                      |> Map.put(:id, Ecto.UUID.generate())

                    unquote(api_module).create(
                      unquote_splicing(
                        Enum.map(rels, fn rel ->
                          Macro.var(rel[:name], nil)
                        end)
                      ),
                      args
                    )
                  end
                end
            end
          )
        end
      end
    end)
  end

  defp with_resolver_update_fun(funs, e, schema, api_module) do
    with_entity_funs(funs, e, :update, fn ->
      quote do
        def update(_, %{id: id} = args, _) do
          unquote(resolver_arg_transforms_block(e))

          with {:ok, entity} <- unquote(api_module).get_by_id(id) do
            args = Map.drop(args, [:id])

            unquote(
              case Enum.filter(e[:relations], fn rel -> rel[:kind] == :belongs_to end) do
                [] ->
                  quote do
                    unquote(api_module).update(entity, args)
                  end

                rels ->
                  quote do
                    with unquote_splicing(
                           rels
                           |> Enum.map(fn rel ->
                             parent_var = Macro.var(rel[:name], nil)
                             target = find_entity!(schema, rel[:target])

                             quote do
                               {:ok, unquote(parent_var)} <-
                                 unquote(target[:api_module]).get_by_id(args.unquote(rel[:name]))
                             end
                           end)
                         ) do
                      args = Map.drop(args, unquote(Enum.map(rels, fn rel -> rel[:name] end)))

                      unquote(api_module).update(
                        unquote_splicing(
                          Enum.map(rels, fn rel ->
                            Macro.var(rel[:name], nil)
                          end)
                        ),
                        entity,
                        args
                      )
                    end
                  end
              end
            )
          end
        end
      end
    end)
  end

  defp with_resolver_delete_fun(funs, e, _schema, api_module) do
    with_entity_funs(funs, e, :delete, fn ->
      quote do
        def delete(_, %{id: id}, _) do
          with {:ok, entity} <- unquote(api_module).get_by_id(id) do
            unquote(api_module).delete(entity)
          end
        end
      end
    end)
  end

  defp resolver_module(e, schema, _) do
    api_module = e[:api_module]

    resolver_funs =
      []
      |> with_resolver_list_funs(e, schema, api_module)
      |> with_resolver_read_funs(e, schema, api_module)
      |> with_resolver_create_fun(e, schema, api_module)
      |> with_resolver_update_fun(e, schema, api_module)
      |> with_resolver_delete_fun(e, schema, api_module)
      |> List.flatten()

    quote do
      defmodule unquote(e[:resolver_module]) do
        def transform_arg(args, arg_name, mod) do
          case Map.fetch(args, arg_name) do
            :error ->
              args

            {:ok, v} ->
              {:ok, Map.put(args, arg_name, v)}
          end
        end

        (unquote_splicing(resolver_funs))
      end
    end
  end

  defp api_module(e, _, opts) do
    schema_module = e[:schema_module]
    repo_module = opts[:repo]

    api_funs =
      []
      |> with_api_list_funs(e, schema_module, repo_module)
      |> with_api_read_funs(e, schema_module, repo_module)
      |> with_api_create_fun(e, schema_module, repo_module)
      |> with_api_update_fun(e, schema_module, repo_module)
      |> with_api_delete_fun(e, schema_module, repo_module)
      |> List.flatten()

    quote do
      defmodule unquote(e[:api_module]) do
        import Ecto.Query, only: [from: 2]
        (unquote_splicing(api_funs))
      end
    end
  end

  defp with_api_list_funs(funs, e, schema_module, repo_module) do
    with_entity_funs(funs, e, :list, fn ->
      [
        quote do
          def list do
            unquote(schema_module)
            |> unquote(repo_module).all()
          end
        end
        | e[:relations]
          |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
          |> Enum.map(fn rel ->
            quote do
              def unquote(String.to_atom("list_by_#{rel[:name]}"))(id) do
                query =
                  from(unquote(Macro.var(rel[:name], nil)) in unquote(schema_module),
                    where:
                      unquote(Macro.var(rel[:name], nil)).unquote(
                        String.to_atom("#{rel[:name]}_id")
                      ) == ^id
                  )

                unquote(repo_module).all(query)
              end
            end
          end)
      ]
    end)
  end

  defp with_api_read_funs(funs, e, schema_module, repo_module) do
    with_entity_funs(funs, e, :read, fn ->
      [
        quote do
          def get_by_id(id) do
            case unquote(schema_module)
                 |> unquote(repo_module).get(id) do
              nil ->
                {:error, :not_found}

              e ->
                {:ok, e}
            end
          end
        end
        | e[:attributes]
          |> Enum.filter(fn attr -> attr[:opts][:unique] end)
          |> Enum.map(fn attr ->
            quote do
              def unquote(String.to_atom("get_by_#{attr[:name]}"))(value) do
                value =
                  case is_atom(value) do
                    true ->
                      "#{value}"

                    false ->
                      value
                  end

                case unquote(schema_module)
                     |> unquote(repo_module).get_by([{unquote(attr[:name]), value}]) do
                  nil ->
                    {:error, :not_found}

                  e ->
                    {:ok, e}
                end
              end
            end
          end)
      ]
    end)
  end

  defp with_api_create_fun(funs, e, schema_module, repo_module) do
    with_entity_funs(funs, e, :create, fn ->
      fun_body =
        case virtual?(e) do
          true ->
            quote do
              unquote(e[:actions][:create][:using]).execute(attrs)
            end

          false ->
            quote do
              with {:ok, e} <-
                     %unquote(schema_module){}
                     |> unquote(schema_module).changeset(attrs)
                     |> unquote(repo_module).insert() do
                get_by_id(e.id)
              end
            end
        end

      quote do
        def create(
              unquote_splicing(
                e[:relations]
                |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
                |> Enum.map(fn rel -> Macro.var(rel[:name], nil) end)
              ),
              attrs
            ) do
          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              quote do
                attrs =
                  attrs
                  |> Map.put(
                    unquote(String.to_atom("#{rel[:name]}_id")),
                    unquote(Macro.var(rel[:name], nil)).id
                  )
              end
            end)
          )

          unquote(fun_body)
        end
      end
    end)
  end

  defp with_api_update_fun(funs, e, schema_module, repo_module) do
    with_entity_funs(funs, e, :update, fn ->
      quote do
        def update(
              unquote_splicing(
                e[:relations]
                |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
                |> Enum.map(fn rel ->
                  Macro.var(rel[:name], nil)
                end)
              ),
              unquote(Macro.var(e[:name], nil)),
              attrs
            ) do
          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              quote do
                attrs =
                  attrs
                  |> Map.put(
                    unquote(String.to_atom("#{rel[:name]}_id")),
                    unquote(Macro.var(rel[:name], nil)).id
                  )
              end
            end)
          )

          with {:ok, unquote(Macro.var(e[:name], nil))} <-
                 unquote(Macro.var(e[:name], nil))
                 |> unquote(schema_module).changeset(attrs)
                 |> unquote(repo_module).update() do
            get_by_id(unquote(Macro.var(e[:name], nil)).id)
          end
        end
      end
    end)
  end

  defp with_api_delete_fun(funs, e, schema_module, repo_module) do
    with_entity_funs(funs, e, :delete, fn ->
      quote do
        def delete(%unquote(schema_module){} = e) do
          unquote(repo_module).delete(e)
        end
      end
    end)
  end

  defp find_entity!(schema, name) do
    case Enum.filter(schema, fn e ->
           name == e[:name]
         end) do
      [] ->
        raise "Could not resolve entity #{name}: #{
                inspect(Enum.map(schema, fn e -> e[:name] end))
              }"

      [e] ->
        e
    end
  end

  defp attr_graphql_type(e, attr) do
    case attr[:opts][:one_of] do
      nil ->
        # it is not an enum, so we use its defined type
        attr[:kind]

      [_ | _] ->
        # use the name of the enum as the type
        enum_name(e, attr)
    end
  end

  defp graphql_object(e, _schema, opts) do
    quote do
      object unquote(e[:name]) do
        (unquote_splicing(
           # Add a field for each attribute.
           (e[:attributes]
            |> Enum.reject(&secret?(&1))
            |> Enum.map(fn attr ->
              # determine the kind for this field, depending
              # on whether it is an enum or not
              kind = attr_graphql_type(e, attr)

              quote do
                field(unquote(attr[:name]), unquote(kind))
              end
            end)) ++
             Enum.map(e[:relations], fn rel ->
               # Add a field for each relation
               quote do
                 field(
                   unquote(rel[:name]),
                   unquote(
                     case rel[:kind] do
                       :has_many ->
                         quote do
                           list_of(unquote(rel[:target]))
                         end

                       _ ->
                         quote do
                           non_null(unquote(rel[:target]))
                         end
                     end
                   ),
                   resolve: dataloader(unquote(opts[:caller]).Dataloader.Repo)
                 )
               end
             end)
         ))
      end
    end
  end

  defp graphql_enum(e, _) do
    Enum.map(e[:enums], fn enum ->
      quote do
        enum unquote(enum[:name]) do
          (unquote_splicing(
             Enum.map(enum[:values], fn value ->
               quote do
                 value(unquote(value), as: unquote("#{value}"))
               end
             end)
           ))
        end
      end
    end)
  end

  defp action?(e, action) do
    Enum.member?(e[:opts][:actions], action)
  end

  defp single_graphql_queries(e, schema) do
    case action?(e, :read) do
      true ->
        quote do
          object unquote(String.to_atom("#{e[:name]}_queries")) do
            (unquote_splicing(
               List.flatten([
                 graphql_query_find_by_id(e, schema),
                 graphql_query_find_by_unique_fields(e, schema)
               ])
             ))
          end
        end

      false ->
        nil
    end
  end

  defp multiple_graphql_queries(e, schema) do
    case action?(e, :list) do
      true ->
        quote do
          object unquote(String.to_atom("#{e[:plural]}_queries")) do
            (unquote_splicing(
               List.flatten([
                 graphql_query_list_all(e, schema),
                 graphql_query_find_by_parent_types(e, schema)
               ])
             ))
          end
        end

      false ->
        nil
    end
  end

  defp graphql_query_list_all(e, _schema) do
    quote do
      @desc "List all " <> unquote("#{e[:plural_display_name]}")
      field :all, list_of(unquote(e[:name])) do
        resolve(&unquote(e[:resolver_module]).list_all/3)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field :by_id,
            unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).get_by_id/3)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(e, _schema) do
    e[:attributes]
    |> Enum.filter(fn attr -> Keyword.get(attr[:opts], :unique) end)
    |> Enum.map(fn attr ->
      kind = attr_graphql_type(e, attr)

      quote do
        @desc "Find a single " <>
                unquote("#{e[:display_name]}") <>
                " given its unique " <> unquote("#{attr[:name]}")
        field unquote(String.to_atom("by_#{attr[:name]}")),
              unquote(e[:name]) do
          arg(unquote(attr[:name]), non_null(unquote(kind)))

          resolve(
            &(unquote(e[:resolver_module]).unquote(String.to_atom("get_by_#{attr[:name]}")) / 3)
          )
        end
      end
    end)
  end

  defp graphql_query_find_by_parent_types(e, _schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
    |> Enum.map(fn rel ->
      quote do
        @desc "Find all " <>
                unquote("#{e[:plural_display_name]}") <>
                " given their parent " <> unquote("#{rel[:target]}")
        field unquote(String.to_atom("by_#{rel[:name]}")),
              list_of(unquote(e[:name])) do
          arg(unquote(rel[:name]), non_null(:id))

          resolve(
            &(unquote(e[:resolver_module]).unquote(String.to_atom("list_by_#{rel[:name]}")) / 3)
          )
        end
      end
    end)
  end

  defp graphql_mutations(e, schema) do
    quote do
      object unquote(String.to_atom("#{e[:name]}_mutations")) do
        (unquote_splicing(
           List.flatten([
             if_entity_action(e, :create, fn -> graphql_create_mutation(e, schema) end),
             if_entity_action(e, :update, fn -> graphql_update_mutation(e, schema) end),
             if_entity_action(e, :delete, fn -> graphql_delete_mutation(e, schema) end)
           ])
           |> without_nils()
         ))
      end
    end
  end

  defp readonly?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :readonly)
  end

  defp optional?(attr) do
    Enum.member?(attr[:opts][:modifiers] || [], :optional)
  end

  defp graphql_create_mutation(e, _schema) do
    return_type =
      case e[:actions][:create] do
        nil ->
          e[:name]

        opts ->
          opts[:produces]
      end

    quote do
      @desc unquote("Create a new #{e[:display_name]}")
      field :create, non_null(unquote(return_type)) do
        unquote_splicing(
          (e[:attributes]
           |> Enum.reject(fn attr -> attr[:name] == :id end)
           |> Enum.reject(&readonly?(&1))
           |> Enum.map(fn attr ->
             kind = attr_graphql_type(e, attr)

             quote do
               arg(
                 unquote(attr[:name]),
                 unquote(
                   case optional?(attr) do
                     true ->
                       kind

                     false ->
                       quote do
                         non_null(unquote(kind))
                       end
                   end
                 )
               )
             end
           end)) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), non_null(:id))
               end
             end))
        )

        resolve(&unquote(e[:resolver_module]).create/3)
      end
    end
  end

  defp graphql_update_mutation(e, _schema) do
    quote do
      @desc unquote("Update an existing #{e[:display_name]}")
      field :update, non_null(unquote(e[:name])) do
        unquote_splicing(
          [
            quote do
              arg(:id, non_null(:id))
            end
          ] ++
            (e[:attributes]
             |> Enum.reject(fn attr ->
               attr[:name] == :id || Enum.member?(attr[:opts][:modifiers] || [], :readonly)
             end)
             |> Enum.map(fn attr ->
               quote do
                 arg(unquote(attr[:name]), unquote(attr[:kind]))
               end
             end)) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), :id)
               end
             end))
        )

        resolve(&unquote(e[:resolver_module]).update/3)
      end
    end
  end

  defp graphql_delete_mutation(e, _schema) do
    quote do
      @desc "Delete an existing " <> unquote("#{e[:display_name]}")
      field :delete, unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).delete/3)
      end
    end
  end

  defp attributes_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:attribute, _, attr} ->
        attribute(attr)

      _ ->
        nil
    end)
    |> Enum.reject(fn attr -> attr == nil end)
  end

  defp attributes_from({:attribute, _, attr}) do
    [attribute(attr)]
  end

  defp attributes_from(_) do
    []
  end

  defp attribute([name, kind]), do: [name: name, kind: kind, opts: []]
  defp attribute([name, kind, opts]), do: [name: name, kind: kind, opts: opts]

  defp relations_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:has_many, _, [name]} ->
        [name: name, kind: :has_many, opts: []]

      {:has_many, _, [name, opts]} ->
        [name: name, kind: :has_many, opts: opts]

      {:has_one, _, [name]} ->
        [name: name, kind: :has_one, opts: []]

      {:has_one, _, [name, opts]} ->
        [name: name, kind: :has_one, opts: opts]

      {:belongs_to, _, [name]} ->
        [name: name, kind: :belongs_to, opts: []]

      {:belongs_to, _, [name, opts]} ->
        [name: name, kind: :belongs_to, opts: opts]

      _ ->
        nil
    end)
    |> Enum.reject(fn rel -> rel == nil end)
  end

  defp relations_from(_) do
    []
  end

  defp actions_from({:__block__, [], actions}) do
    actions
    |> Enum.reduce([], fn
      {action, _, [opts]}, acc
      when action == :create or action == :update or action == :read or action == :list ->
        opts =
          case opts[:using] do
            nil ->
              opts

            {:__aliases__, _, mod} ->
              Keyword.put(opts, :using, Module.concat(mod))
          end

        Keyword.put(acc, action, opts)

      _, acc ->
        acc
    end)
    |> without_nils()
  end

  defp actions_from(_), do: []
end
