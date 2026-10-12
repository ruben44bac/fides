defmodule Fides.Origination.Lifecycle.Transition do
  @moduledoc "One allowed move between states, who may make it and the condition it needs, if any."

  @enforce_keys [:from, :to, :actors]
  defstruct [:from, :to, :actors, :guard]

  @type t :: %__MODULE__{from: atom(), to: atom(), actors: [atom()], guard: atom() | nil}

  @spec new({atom(), atom(), [atom()]} | {atom(), atom(), [atom()], atom()}) :: t()
  def new({from, to, actors}), do: %__MODULE__{from: from, to: to, actors: actors}

  def new({from, to, actors, guard}),
    do: %__MODULE__{from: from, to: to, actors: actors, guard: guard}
end
