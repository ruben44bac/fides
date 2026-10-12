defmodule Fides.Platform.Checks.Agent do
  @moduledoc "Policy check: the actor is one of the agents in `names`."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor is the agent #{Enum.join(opts[:names], " or ")}"

  @impl true
  def match?(%Fides.Platform.AgentActor{name: name}, _context, opts), do: name in opts[:names]
  def match?(_actor, _context, _opts), do: false
end
