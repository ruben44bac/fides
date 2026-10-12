defmodule Fides.Countries.TestDomain do
  @moduledoc "Accepts resources defined inside tests, under the Countries context."

  use Fides.Platform.Domain,
    boundary: [top_level?: true, check: [in: false, out: false]],
    validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end
