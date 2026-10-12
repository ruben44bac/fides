defmodule Fides.Platform.Audited.Info do
  @moduledoc "Introspection for `Fides.Platform.Audited`."

  use Spark.InfoGenerator,
    extension: Fides.Platform.Audited,
    sections: [:audit]

  @doc "Columns that cannot change after insert, `country_code` included when present."
  @spec immutable_columns(Ash.Resource.t() | map()) :: [atom()]
  def immutable_columns(resource_or_dsl) do
    Spark.Dsl.Extension.get_persisted(resource_or_dsl, :fides_immutable_columns, [])
  end
end
