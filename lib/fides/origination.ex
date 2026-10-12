defmodule Fides.Origination do
  @moduledoc """
  Origination context: the credit application, its revisions and its life cycle in
  each country. A change of state is a command with an actor, never an edit.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  @doc "The target states an actor may move an application to from `state`."
  defdelegate available_transitions(country, state, actor, context \\ %{}),
    to: Fides.Origination.Lifecycle,
    as: :available
end
