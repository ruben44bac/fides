defmodule Fides.Platform.Checks.SystemActor do
  @moduledoc "Policy check: the actor is a `Fides.Platform.SystemActor`."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a system process"

  @impl true
  def match?(%Fides.Platform.SystemActor{}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
