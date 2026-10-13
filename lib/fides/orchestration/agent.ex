defmodule Fides.Orchestration.Agent do
  @moduledoc """
  What each agent implements. An agent is given an assignment and proposes what comes
  next; it never writes the application's state. Only the orchestrator does, after
  checking that the application is still at the version the agent saw.

    * `{:advance, %{to: state, tool: tool, facts: facts}}` proposes moving the
      application to `state`, with what the agent found using `tool`: each fact a
      name and a map.
    * `{:retry, reason}` asks to run again later, for a failure that may pass.
    * `{:escalate, reason}` hands the case to a person.

  Each agent runs in its own queue, with its own identity. When an agent asks to
  retry on its last attempt, it proposes what `exhausted/2` gives instead; without
  it, the case escalates.
  """

  alias Fides.Orchestration.Assignment

  @type proposal ::
          {:advance, %{to: atom(), tool: String.t(), facts: %{optional(atom()) => map()}}}
          | {:retry, String.t()}
          | {:escalate, String.t()}

  @doc "The name the life cycles give the agent, as in `{:agent, :intake}`."
  @callback name() :: atom()

  @doc "The version of the agent's logic, recorded with each of its runs."
  @callback version() :: pos_integer()

  @doc "The Oban queue the agent runs in for an assignment, such as one per provider."
  @callback queue(Assignment.t()) :: atom()

  @callback run(Assignment.t()) :: proposal()

  @doc "What the agent proposes when its last attempt asked to retry, with the reason."
  @callback exhausted(Assignment.t(), reason :: String.t()) :: proposal()

  @optional_callbacks exhausted: 2
end
