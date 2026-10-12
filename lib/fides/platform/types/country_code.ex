defmodule Fides.Platform.Types.CountryCode do
  @moduledoc """
  An ISO 3166-1 alpha-2 country code. Stored as `varchar(2)` rather than `char(2)`,
  so filters on several countries can still use an index that starts with it.
  """

  use Ash.Type.NewType, subtype_of: :string, constraints: [min_length: 2, max_length: 2]
  use AshPostgres.Type

  @impl AshPostgres.Type
  def migration_type(_constraints), do: {:varchar, 2}
end
