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
end
