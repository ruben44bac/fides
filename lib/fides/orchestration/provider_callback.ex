defmodule Fides.Orchestration.ProviderCallback do
  @moduledoc """
  Applies the data a provider delivered later: finds the call the delivery answers and
  its application and, if the application is still waiting for the provider, keeps the
  profile and confirms the Banking agent's move to the evaluation. A delivery for an
  application that has moved on, or that answers no pending call, is recorded as
  ignored and changes nothing. The event is processed once.
  """

  use Oban.Worker,
    queue: :orchestration,
    max_attempts: 5,
    unique: [keys: [:country_code, :provider, :event_id], period: :infinity]

  alias Fides.Orchestration.Agents.Banking
  alias Fides.Orchestration.Orchestrator
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @actor SystemActor.new(:provider_callback)

  @doc "Enqueues the delivery, once the event is recorded."
  @spec enqueue(String.t(), struct(), struct(), map()) :: :ok | {:error, term()}
  def enqueue(country, provider, event, parsed) do
    %{
      country_code: country,
      provider: provider.adapter,
      provider_id: provider.id,
      event_id: event.id,
      request_id: parsed.envelope.request_id,
      profile: Map.from_struct(parsed.profile),
      payload_hash: Base.encode16(parsed.payload_hash, case: :lower)
    }
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"country_code" => country, "event_id" => event_id, "request_id" => request_id} = args
    opts = [tenant: country, actor: @actor]

    with {:ok, exchange} when not is_nil(exchange) <-
           Fides.Banking.pending_exchange(country, request_id, @actor),
         {:ok, %{state: :awaiting_bank_callback} = application} <-
           Orchestrator.application(exchange.application_id) do
      run = %{job_id: job.id, attempt: job.attempt, started: System.monotonic_time(:millisecond)}
      profile = keep_profile!(application, exchange, args, opts)
      :ok = Orchestrator.confirm(application, Banking, proposal(profile), run)
      mark!(event_id, :applied, opts)
    else
      {:ok, _no_exchange_or_moved_on} -> mark!(event_id, :ignored, opts)
      {:error, :not_found} -> mark!(event_id, :ignored, opts)
      {:error, error} -> {:error, error}
    end
  end

  defp keep_profile!(application, exchange, args, opts) do
    AuditContext.run([actor: SystemActor.audit_id(@actor), reason: "provider webhook"], fn ->
      args["profile"]
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.merge(%{
        provider_id: args["provider_id"],
        application_id: application.id,
        exchange_id: exchange.id,
        origin: :live,
        payload_hash: Base.decode16!(args["payload_hash"], case: :lower)
      })
      |> Fides.Banking.record_bank_profile!(opts)
    end)
  end

  defp proposal(profile) do
    {:advance,
     %{
       to: :evaluating,
       tool: "banking.fetch_profile",
       facts: %{bank_profile: %{id: profile.id, origin: profile.origin}}
     }}
  end

  defp mark!(event_id, result, opts) do
    event = Fides.Notifications.get_inbound_event!(event_id, opts)
    Fides.Notifications.mark_event_processed!(event, result, opts)
    :ok
  end
end
