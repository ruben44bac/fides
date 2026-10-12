defmodule Fides.Platform.Classification.Persisters.EnforceClassification do
  @moduledoc false
  # A persister, not a verifier: Spark turns verifier errors into warnings, while a
  # persister error aborts compilation. Persisters run after every transformer of
  # every extension, so attributes added by AshCloak, AshStateMachine or belongs_to
  # already exist. `before?/1` puts it ahead of Ash's persisters, so the `sensitive?`
  # flag set here is what the Ecto schema and Inspect implementation use.

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @sensitive_classes [:pii, :internal]

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    with {:ok, classes} <- Fides.Platform.Classification.Check.run(dsl) do
      dsl =
        dsl
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&(Map.get(classes, &1.name) in @sensitive_classes and not &1.sensitive?))
        |> Enum.reduce(dsl, fn attribute, dsl ->
          Transformer.replace_entity(
            dsl,
            [:attributes],
            %{attribute | sensitive?: true},
            &(&1.name == attribute.name)
          )
        end)

      {:ok, Transformer.persist(dsl, :fides_classification, classes)}
    end
  end
end
