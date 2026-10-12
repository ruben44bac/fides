defmodule Fides.Platform.Classification.Check do
  @moduledoc false
  # Pure check over a resource's DSL state.

  alias Spark.Dsl.Transformer

  @doc "Returns `{:ok, %{attribute => class}}` or `{:error, %Spark.Error.DslError{}}`."
  def run(dsl) do
    entries = Fides.Platform.Classification.Info.classification(dsl)
    attributes = dsl |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
    cloaked = cloaked_attributes(dsl)
    declared = Map.new(entries, &{&1.name, &1.class})

    # AshCloak renames `email` to `encrypted_email`, so classifying the logical name
    # covers the stored attribute.
    logical_names = Map.new(cloaked, &{"encrypted_#{&1}", &1})
    resolved = Map.new(attributes, &{&1, class_of(&1, declared, logical_names)})

    unclassified = for attribute <- attributes, is_nil(resolved[attribute]), do: attribute
    unknown = Map.keys(declared) -- (attributes ++ cloaked)
    duplicates = duplicates(entries)

    case problems(unclassified, unknown, duplicates) do
      [] ->
        {:ok, resolved}

      problems ->
        {:error,
         Spark.Error.DslError.exception(
           module: Transformer.get_persisted(dsl, :module),
           path: [:classification],
           location: Transformer.get_section_anno(dsl, [:classification]),
           message: Enum.join(problems, "\n  ")
         )}
    end
  end

  defp class_of(attribute, declared, logical_names) do
    Map.get(declared, attribute) ||
      Map.get(declared, Map.get(logical_names, Atom.to_string(attribute)))
  end

  defp duplicates(entries) do
    for {name, count} <- Enum.frequencies_by(entries, & &1.name), count > 1, do: name
  end

  defp problems(unclassified, unknown, duplicates) do
    [
      {unclassified, "attributes without classification"},
      {unknown, "classification for unknown attributes"},
      {duplicates, "attributes classified more than once"}
    ]
    |> Enum.reject(fn {names, _message} -> names == [] end)
    |> Enum.map(fn {names, message} -> "#{message}: #{inspect(names)}" end)
  end

  defp cloaked_attributes(dsl) do
    if AshCloak in Transformer.get_persisted(dsl, :extensions, []) do
      AshCloak.Info.cloak_attributes!(dsl)
    else
      []
    end
  end
end
