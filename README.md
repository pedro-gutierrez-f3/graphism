# Graphism

An Elixir DSL that makes it easier to build Absinthe powered GraphQL apis 
on top of Ecto and Postgres.

<p align="center">
  <img height="350" src="https://support.bite.social/images/graphism.png">
</p>

## Installation :construction:

This library can be installed by adding `graphism` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:graphism,
        git: "https://github.com/gravity-core/graphism.git", branch: "main"}
  ]
end
```

## Your first schema :world_map:

Define a new schema module 

```elixir
defmodule MyBlogWeb.Schema do
  use Graphism,
    repo: MyBlog.Repo

    
  entity :post do
    attribute :id, :id
    attribute :title, :string
    attribute :body, :string
    has_many :comments
  end

  entity :comment do
    attribute :id, :id
    attribute :body, :string
    belongs_to :post
  end
end

```

## Generate migrations :building_construction:

Graphism will keep track of your schema changes and 
generate proper Ecto migrations:


First, you need to tell graphism about your schema. In your config.exs,


```elixir
config :graphism,
  schema: MyBlogWeb.Schema
```

Then:

```
$ mix graphism.gen.migrations

```

Do not forget to run `mix ecto.migrate` afterwards.


## Schema Modifiers :abacus:

We have two types of modifiers. Entity modifiers and attribute modifiers. They both allow customizations in behaviour.

### Entity modifiers

| Modifier | Description |
| --- | --- | 
| `internal`   |  indicates the entity is persisted, but is not part of the graphql api |
| `virtual` | indicates the entity is part of the graphql api, but is not persisted |

### Attribute modifiers

| Modifier | Description |
| --- | --- | 
| `optional`    |  indicates the attribute is optional (ie can be omitted in mutations, and will accept null values in the database) |
| `secret`    | indicates the attribute is write only (can't be read) from the graphql api|
| `readonly`    | indicates the attribute can only be read from the graphql api|


## Github Workflow :dna:
Our commit convention follows [conventionalcommits.org](https://www.conventionalcommits.org) workflow.

### General commit message pattern
`type(scope?): description`

* `type` - Possible values are `feat | fix | refactor | perf | docs | style | test | chore | ci`.
* `scope` - Any scope to which `type` applies, usually we either omit scope or use the component name / part of the app name.
* `description` - Description of changes, needs to start with **lowercase** character to pass checks.

### Supported types:
 - **feat** - a new feature

  `feat(scope): description` or `feat: description`
 - **fix** - a bug fix

  `fix(scope): description` or `fix: description`
 - **refactor** - a code change that neither fixes a bug nor adds a feature

  `refactor(scope): description` or `refactor: description`
 - **perf** - a code change that improves performance

  `perf(scope): description` or `perf: description`
 - **docs** - documentation only changes

  `docs(scope): description` or `docs: description`
 - **style** - changes that do not affect the meaning of the code (white-space, formatting, missing semi-colons, etc)

  `style(scope): description` or `style: description`
 - **test** - adding missing tests or correcting existing tests

  `test(scope): description` or `test: description`
 - **chore** - other changes that don't modify src or test files

  `chore(scope): description` or `chore: description`
 - **ci** - changes to our CI configuration files and scripts

  `ci(scope): description` or `ci: description`

### Introducing breaking changes
We try to always provide backward-compatible changes to our API but, if it’s necessary we might introduce a breaking change, we can do it by adding magic constant `BREAKING CHANGE` somewhere to commit description. This triggers `major` version bump to the package version.
