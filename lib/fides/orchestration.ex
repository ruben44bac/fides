defmodule Fides.Orchestration do
  @moduledoc """
  Orchestration context: moves each application through its country's life cycle.

  Every write to an application enqueues a step, in the same transaction. The step
  runs what the life cycle declares on entering the current state; the agents it
  calls propose what comes next, and the orchestrator confirms a proposal only if the
  application is still at the version the agent saw. What the agents find is kept as
  facts of the case, and every agent run leaves a record.
  """

  use Fides.Platform.Domain,
    boundary: [
      deps: [Fides.Platform, Fides.Origination, Fides.Identity, Fides.Banking],
      exports: []
    ]

  resources do
    resource Fides.Orchestration.AgentRun do
      define :record_agent_run, action: :record
      define :list_agent_runs, action: :read
    end

    resource Fides.Orchestration.CaseFact do
      define :record_case_fact, action: :record
      define :list_case_facts, action: :read
    end
  end
end
