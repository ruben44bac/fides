defmodule Fides.Orchestration.Agents.Intake do
  @moduledoc """
  Checks the holder on entering validation: whether their document is still valid
  for the country with the name they keep, and whether they are an adult where the
  document encodes a birth date.

  It sees the name and the document only to check them, through the tool its identity
  may use, and leaves what it finds as facts of the case. It always proposes moving on
  to the bank data: an invalid document or a minor is for the risk evaluation to
  reject, with its reason.
  """

  @behaviour Fides.Orchestration.Agent

  alias Fides.Platform.AgentActor

  @impl true
  def name, do: :intake

  @impl true
  def version, do: 1

  @impl true
  def queue, do: :intake

  @impl true
  def run(assignment) do
    actor = AgentActor.new(:intake)

    case Fides.Identity.check_holder(assignment.country_code, assignment.person_id, actor) do
      {:ok, found} ->
        {:advance,
         %{
           to: :awaiting_bank_data,
           tool: "identity.validate_document",
           facts: %{
             document: %{valid: found.document_valid?},
             adulthood: %{adult: found.adult?, verified_at: found.adult_verified_at}
           }
         }}

      {:error, error} ->
        {:retry, Exception.message(error)}
    end
  end
end
