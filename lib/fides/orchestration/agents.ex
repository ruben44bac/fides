defmodule Fides.Orchestration.Agents do
  @moduledoc """
  The agents the orchestrator can run, by the name the life cycles give them. An
  effect that names an agent not listed here waits until that agent exists.
  """

  alias Fides.Orchestration.Agents.Banking
  alias Fides.Orchestration.Agents.Intake

  @agents [Intake, Banking]

  @spec all() :: [module()]
  def all, do: @agents

  @spec fetch(atom() | String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case Enum.find(@agents, &(Atom.to_string(&1.name()) == to_string(name))) do
      nil -> :error
      agent -> {:ok, agent}
    end
  end
end
