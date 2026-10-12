defmodule Fides.Origination.CreditApplication.Changes.Transition do
  @moduledoc """
  Moves an application through its country's life cycle.

  The actor is the system, or the role of a person's scope in the application's
  country, and the life cycle says which moves each one makes. A person always gives
  a reason, which the evidence records. The update only applies if the application
  is still in the state and version the actor read: otherwise nothing changes.

  Options: `to` fixes the target state, and `reason` the reason, for commands that
  always make the same move. `answer?` marks the answer to a request for information,
  the only way from info_requested back to validation.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Fides.Origination.Lifecycle
  alias Fides.Origination.TransitionNotAllowed
  alias Fides.Platform.Actor
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  require Ash.Expr

  @impl true
  def change(changeset, opts, context) do
    reason = opts[:reason] || argument(changeset, :reason) || argument(changeset, :cause)

    changeset
    |> Ash.Changeset.before_action(&move(&1, opts, reason, context.actor))
    |> audit_reason(reason)
  end

  # After authorization, so an actor who may not act learns nothing from the checks
  defp move(changeset, opts, reason, actor) do
    application = changeset.data
    to = opts[:to] || Ash.Changeset.get_argument(changeset, :to)
    actor = lifecycle_actor(actor, application.country_code)

    with :ok <- check_reason(actor, reason),
         :ok <- check_answer(application.state, to, opts[:answer?] == true),
         :ok <- check_move(application, to, actor),
         {:ok, changeset} <- record_policy_version(changeset, application, actor) do
      changeset
      |> Ash.Changeset.force_change_attribute(:state, to)
      |> expect(application.state, Ash.Changeset.get_argument(changeset, :expected_version))
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp lifecycle_actor(%SystemActor{}, _country), do: :system
  defp lifecycle_actor(actor, country), do: Actor.country_role(actor, country)

  defp argument(changeset, name) do
    case Ash.Changeset.get_argument(changeset, name) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
      _none -> nil
    end
  end

  defp check_reason(:system, _reason), do: :ok
  defp check_reason(_person, reason) when is_binary(reason), do: :ok

  defp check_reason(_person, _reason),
    do: {:error, InvalidArgument.exception(field: :reason, message: "is required from a person")}

  # Leaving info_requested for validation takes an answer, with its new revision
  defp check_answer(:info_requested, :validating, false) do
    {:error,
     InvalidArgument.exception(
       field: :to,
       message: "is reached from info_requested only by answering with the corrected terms"
     )}
  end

  defp check_answer(_from, _to, _answer?), do: :ok

  defp check_move(application, to, actor) do
    context = %{
      amount_minor: application.amount_minor,
      countersign_above_minor: countersign_threshold(application)
    }

    case Lifecycle.transition(application.country_code, application.state, to, actor, context) do
      {:ok, _to} ->
        :ok

      {:error, {:final_state, state}} ->
        {:error, TransitionNotAllowed.exception(from: state, to: to, available: [])}

      {:error, {:not_allowed, available}} ->
        {:error,
         TransitionNotAllowed.exception(from: application.state, to: to, available: available)}
    end
  end

  # Only an analyst's approval from review depends on the threshold
  defp countersign_threshold(%{state: :in_review} = application),
    do: Fides.Risk.countersign_threshold(application.country_code, application.policy_version_id)

  defp countersign_threshold(_application), do: nil

  defp record_policy_version(changeset, application, actor) do
    case Ash.Changeset.get_argument(changeset, :policy_version_id) do
      nil ->
        {:ok, changeset}

      id when actor == :system and application.state == :evaluating ->
        {:ok, Ash.Changeset.force_change_attribute(changeset, :policy_version_id, id)}

      _id ->
        {:error,
         InvalidArgument.exception(
           field: :policy_version_id,
           message: "is only recorded by the system when it decides an evaluation"
         )}
    end
  end

  # The database also sets the next version, the same one when the filter holds; setting
  # it here keeps the returned application in step
  defp expect(changeset, state, version) do
    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(state == ^state and lock_version == ^version))
    |> Ash.Changeset.force_change_attribute(:lock_version, version + 1)
  end

  # The reason becomes the reason of the move's audited transaction
  defp audit_reason(changeset, nil), do: changeset

  defp audit_reason(changeset, reason) do
    Ash.Changeset.around_transaction(changeset, &with_reason(&1, &2, reason))
  end

  # Without an audit context the write fails closed in the database, as any other
  defp with_reason(changeset, callback, reason) do
    case AuditContext.get() do
      nil -> callback.(changeset)
      _context -> AuditContext.run([reason: reason], fn -> callback.(changeset) end)
    end
  end
end
