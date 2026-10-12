defmodule Fides.Platform.Classification.Info do
  @moduledoc "Introspection for `Fides.Platform.Classification`."

  use Spark.InfoGenerator,
    extension: Fides.Platform.Classification,
    sections: [:classification]

  @doc "Map of attribute name => class, computed at compile time."
  @spec classes(Ash.Resource.t() | map()) :: %{atom() => atom()}
  def classes(resource_or_dsl) do
    Spark.Dsl.Extension.get_persisted(resource_or_dsl, :fides_classification, %{})
  end

  @spec class_of(Ash.Resource.t() | map(), atom()) :: atom() | nil
  def class_of(resource_or_dsl, attribute) do
    Map.get(classes(resource_or_dsl), attribute)
  end

  @spec attributes_of_class(Ash.Resource.t() | map(), atom()) :: [atom()]
  def attributes_of_class(resource_or_dsl, class) do
    for {name, ^class} <- classes(resource_or_dsl), do: name
  end
end
