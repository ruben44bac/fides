defmodule Fides.Platform.CountryScoped do
  @moduledoc """
  Spark extension (no DSL) for per-country resources, the ones with a `country_code`:

    * the country is their Ash tenant, so reading or writing one needs a country;
    * the database refuses a `country_code` that is not in `countries`;
    * a table whose key is `id` also exposes a unique `(country_code, id)`, the target
      of the composite foreign keys that keep every row inside its own country.
  """

  use Spark.Dsl.Extension,
    sections: [],
    persisters: [Fides.Platform.CountryScoped.Persisters.ScopeByCountry]
end
