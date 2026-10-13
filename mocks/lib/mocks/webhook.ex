defmodule Mocks.Webhook do
  @moduledoc """
  Delivers Mexico's profile to Fides later, signed as Fides expects:
  `t=<unix seconds>,v1=<HMAC-SHA256 of "<seconds>.<body>" in hex>` in the
  `X-Signature` header. With `MOCKS_WEBHOOK_DUPLICATES`, the same event is delivered
  again, so Fides can show it applies an event once.
  """

  require Logger

  alias Mocks.Settings

  @spec deliver_later(String.t(), Mocks.Providers.profile()) :: :ok
  def deliver_later(request_id, profile) do
    event_id = "evt_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    body = Mocks.Providers.mexican_event(event_id, request_id, 1, profile)

    # The task keeps its callers, so a test's stubbed Fides receives the delivery
    callers = [self() | Process.get(:"$callers", [])]

    {:ok, _task} =
      Task.Supervisor.start_child(Mocks.Webhooks, fn ->
        Process.put(:"$callers", callers)
        Process.sleep(Settings.webhook_delay_ms())
        for _delivery <- 0..Settings.webhook_duplicates(), do: deliver(body)
      end)

    :ok
  end

  @doc "Sends `body` to Fides, signed at `timestamp`."
  @spec deliver(String.t(), integer()) :: :ok | {:error, term()}
  def deliver(body, timestamp \\ System.os_time(:second)) do
    url = Settings.fides_url() <> "/webhooks/providers/MX"

    headers = [
      {"content-type", "application/json"},
      {"x-signature", sign(Settings.webhook_secret(), body, timestamp)}
    ]

    options =
      [body: body, headers: headers, retry: false] ++
        Application.get_env(:mocks, :req_options, [])

    case Req.post(url, options) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("Fides answered #{status} to the Mexican webhook")
        {:error, status}

      {:error, exception} ->
        Logger.warning("Fides could not be reached: #{Exception.message(exception)}")
        {:error, exception}
    end
  end

  @spec sign(String.t(), String.t(), integer()) :: String.t()
  def sign(secret, body, timestamp) do
    digest =
      :hmac |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{digest}"
  end
end
