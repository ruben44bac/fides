defmodule Fides.Countries do
  @moduledoc """
  Countries context: the country is the root of the data model. Every per-country
  table points at `countries`, and each country's package composes what the other
  contexts define for it.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  resources do
    resource Fides.Countries.Country do
      define :get_country, action: :read, get_by: [:code]
      define :list_countries, action: :read
      define :seed_country, action: :seed
    end
  end
end
