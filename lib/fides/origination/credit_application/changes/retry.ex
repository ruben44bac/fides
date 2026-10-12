defmodule Fides.Origination.CreditApplication.Changes.Retry do
  @moduledoc """
  Makes the new application a retry of a rejected or cancelled one: same holder and
  currency, pointing back to it. The database lets each application be retried once,
  and only by an application of the same holder.
  """

  use Ash.Resource.Change

  @retriable [:rejected, :cancelled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      id = Ash.Changeset.get_argument(changeset, :previous_application_id)

      case Ash.get(changeset.resource, id, tenant: changeset.tenant, authorize?: false) do
        {:ok, %{state: state} = previous} when state in @retriable ->
          changeset
          |> Ash.Changeset.force_change_attribute(:previous_application_id, previous.id)
          |> Ash.Changeset.force_change_attribute(:person_id, previous.person_id)
          |> Ash.Changeset.force_change_attribute(:currency, previous.currency)

        {:ok, previous} ->
          Ash.Changeset.add_error(changeset,
            field: :previous_application_id,
            message: "is #{previous.state}: only a rejected or cancelled application is retried"
          )

        {:error, _not_found} ->
          Ash.Changeset.add_error(changeset,
            field: :previous_application_id,
            message: "is not an application of the country"
          )
      end
    end)
  end
end
