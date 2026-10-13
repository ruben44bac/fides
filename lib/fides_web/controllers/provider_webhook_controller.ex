defmodule FidesWeb.ProviderWebhookController do
  @moduledoc """
  Receives the data a country's asynchronous bank provider delivers later, signed.
  Every delivery is recorded; one with a valid signature is answered at once and
  applied afterwards, by a job, and a repeated one is answered without being applied
  again. An invalid signature is refused and recorded as such.
  """

  use FidesWeb, :controller

  alias Fides.Platform.SystemActor

  @actor SystemActor.new(:webhooks)

  def create(conn, %{"country" => country}) do
    body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("x-signature") |> List.first()

    case Fides.Banking.verify_callback(country, signature, body) do
      {:ok, provider, parsed} ->
        receive_valid(conn, country, provider, parsed)

      {:error, provider, {:signature, _reason}} ->
        record(country, provider, Fides.Banking.callback_envelope(provider, body), body, false)
        answer(conn, 401, "the signature is not valid")

      {:error, provider, {:malformed, field}} ->
        {:ok, event} =
          record(country, provider, Fides.Banking.callback_envelope(provider, body), body, true)

        mark(event, country, :rejected)
        answer(conn, 400, "the body is malformed: #{field}")

      {:error, :no_provider} ->
        answer(conn, 404, "no provider of #{country} delivers data this way")
    end
  end

  defp receive_valid(conn, country, provider, parsed) do
    case record(country, provider, parsed.envelope, nil, true, parsed.payload_hash) do
      {:ok, event} ->
        :ok = Fides.Orchestration.provider_callback(country, provider, event, parsed)
        answer(conn, 202, "received")

      {:error, error} ->
        if Exception.message(error) =~ "already received",
          do: answer(conn, 202, "already received"),
          else: raise(error)
    end
  end

  defp record(country, provider, envelope, body, valid?, payload_hash \\ nil) do
    Fides.Notifications.receive_event(
      %{
        provider: provider.adapter,
        event_id: envelope.event_id,
        sequence: envelope.sequence,
        request_id: envelope.request_id,
        signature_valid: valid?,
        payload_hash: payload_hash || :crypto.hash(:sha256, body)
      },
      tenant: country,
      actor: @actor
    )
  end

  defp mark(event, country, result),
    do: Fides.Notifications.mark_event_processed!(event, result, tenant: country, actor: @actor)

  defp answer(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{status: status, detail: detail})
  end
end
