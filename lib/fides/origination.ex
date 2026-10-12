defmodule Fides.Origination do
  @moduledoc """
  Origination context: the credit application, its revisions and its life cycle in
  each country. A change of state is a command with an actor, never an edit.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform, Fides.Identity, Fides.Risk], exports: []]

  resources do
    resource Fides.Origination.CreditApplication do
      define :submit_application, action: :submit
      define :reapply, action: :reapply
      define :get_application, action: :read, get_by: [:id]
      define :list_applications, action: :read
      define :transition_application, action: :transition, args: [:to, :expected_version]
      define :answer_information_request, action: :respond
      define :reevaluate_application, action: :reevaluate, args: [:cause, :expected_version]
    end

    resource Fides.Origination.ApplicationRevision do
      define :list_revisions, action: :read
    end
  end

  @doc "The target states an actor may move an application to from `state`."
  defdelegate available_transitions(country, state, actor, context \\ %{}),
    to: Fides.Origination.Lifecycle,
    as: :available
end
