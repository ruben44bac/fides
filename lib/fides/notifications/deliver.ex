defmodule Fides.Notifications.Deliver do
  @moduledoc """
  Sends one delivery to its receiver, signed with the receiver's secret, and records
  how it went. A receiver that does not answer 2xx is tried again with backoff; after
  the last attempt the delivery is failed, for the console to send again. It runs with
  the notifier's identity, which decrypts a secret only to sign.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 8,
    unique: [keys: [:delivery_id], period: :infinity]

  alias Fides.Notifications.Event
  alias Fides.Notifications.Signature
  alias Fides.Notifications.WebhookEndpoint
  alias Fides.Platform.AgentActor

  @actor AgentActor.new(:notifier)

  @spec enqueue(struct()) :: :ok | {:error, term()}
  def enqueue(delivery) do
    %{country_code: delivery.country_code, delivery_id: delivery.id}
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"country_code" => country, "delivery_id" => id}} = job) do
    opts = [tenant: country, actor: @actor]

    with {:ok, delivery} <- Fides.Notifications.get_delivery(id, opts),
         {:ok, endpoint} <-
           Ash.get(WebhookEndpoint, delivery.endpoint_id,
             actor: @actor,
             load: [:secret],
             context: %{fides: %{decrypt: :deliver}}
           ) do
      endpoint
      |> send_event(delivery)
      |> record(delivery, job, opts)
    end
  end

  defp send_event(endpoint, delivery) do
    body = Event.body(delivery.payload)

    headers = [
      {"content-type", "application/json"},
      {"x-event-id", delivery.event_id},
      {"x-signature", Signature.sign(endpoint.secret, body, System.os_time(:second))}
    ]

    case Req.post(endpoint.url, [body: body, headers: headers, retry: false] ++ config()) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, exception} -> {:error, exception}
    end
  end

  # Delivered on a 2xx; otherwise pending until the last attempt, then failed
  defp record({:ok, status}, delivery, _job, opts) when status in 200..299 do
    Fides.Notifications.record_delivery_attempt!(delivery, :delivered, status, opts)
    :ok
  end

  defp record({:ok, status}, delivery, job, opts) do
    Fides.Notifications.record_delivery_attempt!(delivery, outcome(job), status, opts)
    {:error, "the receiver answered #{status}"}
  end

  defp record({:error, exception}, delivery, job, opts) do
    Fides.Notifications.record_delivery_attempt!(delivery, outcome(job), nil, opts)
    {:error, "the receiver could not be reached: #{Exception.message(exception)}"}
  end

  defp outcome(%{attempt: attempt, max_attempts: max}) when attempt >= max, do: :failed
  defp outcome(_job), do: :pending

  defp config do
    settings = Application.get_env(:fides, __MODULE__, [])

    [receive_timeout: Keyword.get(settings, :receive_timeout, 5_000)] ++
      Keyword.get(settings, :req_options, [])
  end
end
