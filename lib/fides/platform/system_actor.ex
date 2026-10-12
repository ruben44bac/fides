defmodule Fides.Platform.SystemActor do
  @moduledoc """
  Actor for work the system does on its own behalf, such as seeding reference data.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: atom()}

  @spec new(atom()) :: t()
  def new(name) when is_atom(name), do: %__MODULE__{name: name}

  @doc "Pseudonymous id for the audit trail, e.g. `\"system:seeds\"`."
  @spec audit_id(t()) :: String.t()
  def audit_id(%__MODULE__{name: name}), do: "system:#{name}"
end
