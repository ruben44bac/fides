defmodule Fides.Origination.Moves do
  @moduledoc """
  Which moves an actor may make on an application right now.

  The actor is the system, or the role of a person's scope in the application's
  country, and the country's life cycle says which moves each one makes. In countries
  with a countersignature, an approval from review depends on the threshold of the
  policy version the application was evaluated with. Going back from info_requested
  to validation takes an answer with corrected terms, never a plain transition.
  """

  alias Ash.Error.Changes.InvalidArgument
  alias Fides.Origination.Lifecycle
  alias Fides.Origination.TransitionNotAllowed
  alias Fides.Platform.Actor
  alias Fides.Platform.SystemActor

  @doc "The actor's role in the life cycle of an application of `country`, or nil."
  @spec actor_role(term(), String.t()) :: atom() | nil
  def actor_role(%SystemActor{}, _country), do: :system
  def actor_role(actor, country), do: Actor.country_role(actor, country)

  @doc "The states the actor may move the application to with a transition."
  @spec available(struct(), term()) :: [atom()]
  def available(application, actor) do
    role = actor_role(actor, application.country_code)

    application.country_code
    |> Lifecycle.available(application.state, role, guard_context(application))
    |> Enum.reject(&answer_only?(application.state, &1))
  end

  @doc """
  Checks a move to `to` by an actor with `role`. `answer?` marks the answer to a
  request for information, the only way from info_requested back to validation.
  """
  @spec check(struct(), atom(), atom() | nil, boolean()) :: :ok | {:error, Exception.t()}
  def check(application, to, role, answer? \\ false)

  def check(%{state: :info_requested}, :validating, _role, false) do
    {:error,
     InvalidArgument.exception(
       field: :to,
       message: "is reached from info_requested only by answering with the corrected terms"
     )}
  end

  def check(application, to, role, _answer?) do
    %{country_code: country, state: from} = application

    case Lifecycle.transition(country, from, to, role, guard_context(application)) do
      {:ok, _to} ->
        :ok

      {:error, {:final_state, state}} ->
        {:error, TransitionNotAllowed.exception(from: state, to: to, available: [])}

      {:error, {:not_allowed, available}} ->
        available = Enum.reject(available, &answer_only?(from, &1))
        {:error, TransitionNotAllowed.exception(from: from, to: to, available: available)}
    end
  end

  defp answer_only?(from, to), do: from == :info_requested and to == :validating

  # Only an analyst's approval from review depends on the threshold, and only in
  # countries with a countersignature
  defp guard_context(%{state: :in_review, country_code: country} = application) do
    if Lifecycle.countersign?(country) do
      %{
        amount_minor: application.amount_minor,
        countersign_above_minor:
          Fides.Risk.countersign_threshold(country, application.policy_version_id)
      }
    else
      %{}
    end
  end

  defp guard_context(_application), do: %{}
end
