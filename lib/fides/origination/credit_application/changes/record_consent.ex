defmodule Fides.Origination.CreditApplication.Changes.RecordConsent do
  @moduledoc """
  Records the holder's consent to evaluate their credit, with the version of the text
  they accepted and the application's channel, in the same transaction as the
  application.
  """

  use Ash.Resource.Change

  alias Fides.Platform.SystemActor

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      consent = %{
        person_id: Ash.Changeset.get_attribute(changeset, :person_id),
        purpose: :credit_evaluation,
        text_version: Ash.Changeset.get_argument(changeset, :consent_text_version),
        channel: Ash.Changeset.get_attribute(changeset, :channel)
      }

      case Fides.Identity.accept_consent(consent, tenant: changeset.tenant, actor: actor()) do
        {:ok, _consent} -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp actor, do: SystemActor.new(:origination)
end
