defmodule Fides.AI do
  @moduledoc """
  AI context: where a language model assists a person, and never decides. The one
  capability so far is the case brief: a summary of the pseudonymized facts of an
  application for the analyst who reviews it, written by the configured model, a
  simulated one by default, and checked before it is shown. Every invocation leaves
  a run with the model, what went in, what came out and what it cost.
  """

  use Fides.Platform.Domain,
    boundary: [
      deps: [Fides.Platform, Fides.Origination, Fides.Risk, Fides.Orchestration],
      exports: [Model]
    ]

  resources do
    resource Fides.AI.AiRun do
      define :record_ai_run, action: :record
      define :list_ai_runs, action: :read
    end
  end

  @doc """
  Writes the brief of an application for its analyst and records the run. The
  application must be read by the AI's own identity, which sees no personal data.
  """
  defdelegate brief(application, actor), to: Fides.AI.CaseBrief, as: :run

  @doc "What the brief's model gets about an application: financial and public data only."
  defdelegate brief_input(application, actor), to: Fides.AI.CaseBrief, as: :input

  @doc "The latest brief written for an application, or nil."
  @spec latest_brief(String.t(), Ecto.UUID.t(), term()) ::
          {:ok, struct() | nil} | {:error, term()}
  def latest_brief(country, application_id, actor) do
    require Ash.Query

    Fides.AI.AiRun
    |> Ash.Query.filter(capability == :case_brief and subject_id == ^application_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(tenant: country, actor: actor)
  end

  @doc "The model the capabilities run with: the simulated one unless the configuration names another."
  @spec model() :: module()
  def model,
    do: :fides |> Application.get_env(__MODULE__, []) |> Keyword.get(:model, Fides.AI.Models.Mock)
end
