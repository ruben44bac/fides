defmodule Fides.Platform.Resource do
  @moduledoc """
  Base module for every Ash resource in Fides. On top of `use Ash.Resource` it adds:

    * `Fides.Platform.Classification`: every attribute must be classified.
    * `Fides.Platform.Audited`: the table gets its Carbonite trigger and its
      immutable columns.
    * `Fides.Platform.ContextIsolation`: no relationship leaves the context.
    * `Fides.Platform.CountryScoped`: per-country data uses the country as its
      tenant and cannot point at a country Fides does not operate in.

  Defaults to `AshPostgres.DataLayer` and `Ash.Policy.Authorizer`.
  """

  @extensions [
    Fides.Platform.Classification,
    Fides.Platform.Audited,
    Fides.Platform.ContextIsolation,
    Fides.Platform.CountryScoped
  ]

  @doc false
  def extensions, do: @extensions

  defmacro __using__(opts) do
    # The options must reach Spark as a literal: it drops non-literal options.
    opts =
      opts
      |> Keyword.update(:extensions, @extensions, &(@extensions ++ List.wrap(&1)))
      |> Keyword.put_new(:data_layer, AshPostgres.DataLayer)
      |> Keyword.put_new(:authorizers, [Ash.Policy.Authorizer])

    quote do
      use Ash.Resource, unquote(opts)
    end
  end
end
