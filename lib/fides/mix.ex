defmodule Fides.Mix do
  @moduledoc "Boundary for the project's Mix tasks."

  use Boundary, deps: [Fides.Platform, Fides.Accounts, Fides.Origination, Fides.Risk]
end
