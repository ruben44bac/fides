defmodule Fides.Notifications.Announce do
  @moduledoc false
  # One delivery per receiver subscribed to the event in the application's country,
  # each sent by its own job. A receiver already holding the event gets nothing new.

  alias Fides.Notifications.Deliver
  alias Fides.Notifications.Event

  @spec run(struct(), atom(), [atom() | String.t()], term()) :: :ok | {:error, term()}
  def run(application, event, reason_codes, actor) do
    payload = Event.payload(application, event, reason_codes)

    case Fides.Notifications.subscribed_endpoints(event, application.country_code, actor: actor) do
      {:ok, endpoints} -> deliver_to_each(endpoints, application, event, payload, actor)
      {:error, error} -> {:error, error}
    end
  end

  defp deliver_to_each(endpoints, application, event, payload, actor) do
    Enum.reduce_while(endpoints, :ok, fn endpoint, :ok ->
      case deliver(endpoint, application, event, payload, actor) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp deliver(endpoint, application, event, payload, actor) do
    with {:ok, delivery} <-
           Fides.Notifications.announce_delivery(
             %{
               endpoint_id: endpoint.id,
               event_id: payload["event_id"],
               event_type: event,
               application_id: application.id,
               payload: payload,
               payload_hash: :crypto.hash(:sha256, Event.body(payload))
             },
             tenant: application.country_code,
             actor: actor
           ) do
      Deliver.enqueue(delivery)
    end
  end
end
