defmodule Fides.Platform.AgentActor do
  @moduledoc """
  Actor for an agent of the orchestration, such as Intake. Each agent acts with its
  own identity, so policies let it read only what its work needs; an agent never
  writes an application's state.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: atom()}

  @spec new(atom()) :: t()
  def new(name) when is_atom(name), do: %__MODULE__{name: name}

  @doc "Pseudonymous id for the audit trail, e.g. `\"agent:intake\"`."
  @spec audit_id(t()) :: String.t()
  def audit_id(%__MODULE__{name: name}), do: "agent:#{name}"
end
