defmodule Fides.Platform.ContextIsolation.Persisters.NoCrossContextRelationships do
  @moduledoc false
  # Compares module names only: `destination`, `through` and `domain` are plain atoms
  # in the DSL state, so the check never waits for another module to compile and
  # cannot deadlock. A persister error aborts compilation.

  use Spark.Dsl.Transformer

  alias Fides.Platform.Context
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    module = Transformer.get_persisted(dsl, :module)
    own = Context.of(module)

    errors =
      if Transformer.get_persisted(dsl, :embedded?, false) do
        check_relationships([], dsl, own)
      else
        []
        |> check_domain(module, own, Transformer.get_persisted(dsl, :domain))
        |> check_relationships(dsl, own)
      end

    case errors do
      [] ->
        :ok

      errors ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships],
           message: errors |> Enum.reverse() |> Enum.join("\n  ")
         )}
    end
  end

  defp check_domain(errors, module, own, domain) do
    cond do
      is_nil(own) ->
        ["#{inspect(module)} is not under a known Fides.<Context> namespace" | errors]

      Context.of(domain) != own ->
        [
          "#{inspect(module)} must use a domain of #{inspect(own)}, got: #{inspect(domain)}"
          | errors
        ]

      true ->
        errors
    end
  end

  defp check_relationships(errors, dsl, own) do
    outside =
      for relationship <- Ash.Resource.Info.relationships(dsl),
          {key, target} <- targets(relationship),
          not is_nil(target),
          Context.of(target) != own do
        "relationship #{inspect(relationship.name)} #{key} #{inspect(target)} is outside context #{inspect(own)}"
      end

    Enum.reverse(outside, errors)
  end

  defp targets(%{type: :many_to_many} = relationship) do
    [
      destination: relationship.destination,
      domain: relationship.domain,
      through: relationship.through
    ]
  end

  defp targets(relationship) do
    [destination: relationship.destination, domain: Map.get(relationship, :domain)]
  end
end
