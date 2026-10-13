defmodule Fides.Orchestration.Agents.Banking do
  @moduledoc """
  Fetches the holder's bank data on entering `awaiting_bank_data`, from the provider
  of the application's country, in a queue of that provider's own: a slow provider
  never holds the others up.

  It sees the document only to ask the provider, through the tools its identity may
  use. With a provider that answers at once, it keeps the profile and proposes the
  evaluation; with one that answers later, it proposes waiting for the provider's
  webhook. A failed call is retried with backoff, under the same request id, and when
  the retries run out it proposes `provider_error`, from where a scheduled retry starts
  over.
  """

  @behaviour Fides.Orchestration.Agent

  alias Fides.Platform.AgentActor

  @tool "banking.fetch_profile"

  @impl true
  def name, do: :banking

  @impl true
  def version, do: 1

  @impl true
  def queue(assignment), do: :"banking_#{String.downcase(assignment.country_code)}"

  @impl true
  def run(assignment) do
    actor = AgentActor.new(:banking)

    case Fides.Identity.holder_document(assignment.country_code, assignment.person_id, actor) do
      {:ok, holder} ->
        assignment.country_code
        |> Fides.Banking.fetch_profile(
          assignment.application_id,
          holder,
          request_id(assignment),
          actor
        )
        |> propose()

      {:error, error} ->
        {:retry, Exception.message(error)}
    end
  end

  @impl true
  def exhausted(_assignment, reason) do
    {:advance, %{to: :provider_error, tool: @tool, facts: %{provider_error: %{reason: reason}}}}
  end

  @doc "The request id of an assignment: the same across its retries, so the provider answers the same."
  @spec request_id(Fides.Orchestration.Assignment.t()) :: String.t()
  def request_id(assignment), do: "#{assignment.application_id}-#{assignment.lock_version}"

  defp propose({:ok, profile}) do
    {:advance,
     %{
       to: :evaluating,
       tool: @tool,
       facts: %{bank_profile: %{id: profile.id, origin: profile.origin}}
     }}
  end

  defp propose({:accepted, request_id}) do
    {:advance,
     %{
       to: :awaiting_bank_callback,
       tool: @tool,
       facts: %{bank_request: %{request_id: request_id}}
     }}
  end

  defp propose({:error, reason}), do: {:retry, reason}
end
