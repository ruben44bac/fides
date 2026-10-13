defmodule Fides.Origination do
  @moduledoc """
  Origination context: the credit application, its revisions and its life cycle in
  each country. A change of state is a command with an actor, never an edit.
  """

  use Fides.Platform.Domain,
    boundary: [
      deps: [Fides.Platform, Fides.Identity, Fides.Risk],
      exports: [TransitionNotAllowed, Lifecycle.Diagram]
    ],
    extensions: [AshJsonApi.Domain]

  # Client mistakes are answered, not logged as errors
  json_api do
    log_errors? false
    error_handler {Fides.Origination.JsonApiErrors, :handle, []}
  end

  resources do
    resource Fides.Origination.CreditApplication do
      define :submit_application, action: :submit
      define :reapply, action: :reapply
      define :get_application, action: :read, get_by: [:id]
      define :find_application, action: :visible, get_by: [:id], not_found_error?: false
      define :list_applications, action: :read
      define :transition_application, action: :transition, args: [:to, :expected_version]
      define :answer_information_request, action: :respond
      define :reevaluate_application, action: :reevaluate, args: [:cause, :expected_version]
    end

    resource Fides.Origination.ApplicationRevision do
      define :list_revisions, action: :read
    end

    resource Fides.Origination.LifecycleState do
      define :list_lifecycle_states, action: :read
      define :seed_lifecycle_state, action: :seed, args: [:state]
      define :retire_lifecycle_state, action: :retire
    end

    resource Fides.Origination.LifecycleTransition do
      define :list_lifecycle_transitions, action: :read
      define :seed_lifecycle_transition, action: :seed, args: [:from_state, :to_state]
      define :retire_lifecycle_transition, action: :retire
    end

    resource Fides.Origination.ApplicationCommands
  end

  @doc "The target states an actor may move an application to from `state`."
  defdelegate available_transitions(country, state, actor, context \\ %{}),
    to: Fides.Origination.Lifecycle,
    as: :available

  @doc """
  The day the holder's most recent other application was rejected, or nil. A final
  state never changes, so the application's last change is its rejection.
  """
  @spec last_rejection(String.t(), Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, Date.t() | nil} | {:error, term()}
  def last_rejection(country, person_id, except_application_id, actor) do
    require Ash.Query

    Fides.Origination.CreditApplication
    |> Ash.Query.filter(
      person_id == ^person_id and state == :rejected and id != ^except_application_id
    )
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(tenant: country, actor: actor)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, application} -> {:ok, DateTime.to_date(application.updated_at)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The applications of a country waiting for review that were not decided under
  `policy_version_id`: the ones a new version in force sends back to evaluation.
  """
  @spec waiting_under_another_version(String.t(), Ecto.UUID.t(), term()) ::
          {:ok, [struct()]} | {:error, term()}
  def waiting_under_another_version(country, policy_version_id, actor) do
    require Ash.Query

    Fides.Origination.CreditApplication
    |> Ash.Query.filter(
      state == :in_review and
        (is_nil(policy_version_id) or policy_version_id != ^policy_version_id)
    )
    |> Ash.read(tenant: country, actor: actor)
  end

  @doc "Revision `number` of an application's terms."
  @spec revision(String.t(), Ecto.UUID.t(), pos_integer(), term()) ::
          {:ok, struct() | nil} | {:error, term()}
  def revision(country, application_id, number, actor) do
    require Ash.Query

    Fides.Origination.ApplicationRevision
    |> Ash.Query.filter(application_id == ^application_id and number == ^number)
    |> Ash.read_one(tenant: country, actor: actor)
  end

  @doc "What runs on entering each state of a country's life cycle."
  defdelegate life_cycle_effects(country), to: Fides.Origination.Lifecycle, as: :effects
end
