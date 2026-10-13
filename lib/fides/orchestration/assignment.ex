defmodule Fides.Orchestration.Assignment do
  @moduledoc """
  What an agent is given about an application: its id and its holder's, its country,
  its state, its current revision and the version it is at. It carries no personal
  data: an agent loads what else its work needs through the tools its identity
  allows.
  """

  @enforce_keys [:application_id, :country_code, :person_id, :state, :revision, :lock_version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          application_id: Ecto.UUID.t(),
          country_code: String.t(),
          person_id: Ecto.UUID.t(),
          state: atom(),
          revision: pos_integer(),
          lock_version: pos_integer()
        }

  @spec new(struct()) :: t()
  def new(application) do
    %__MODULE__{
      application_id: application.id,
      country_code: application.country_code,
      person_id: application.person_id,
      state: application.state,
      revision: application.revision,
      lock_version: application.lock_version
    }
  end

  @doc "SHA-256 of the assignment, as an agent run records what the agent was given."
  @spec hash(t()) :: binary()
  def hash(%__MODULE__{} = assignment) do
    :crypto.hash(:sha256, :erlang.term_to_binary(Map.from_struct(assignment), [:deterministic]))
  end
end
