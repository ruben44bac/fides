defmodule Fides.Banking.Client do
  @moduledoc """
  Calls a country's bank provider over HTTP. The request carries the holder's
  document and a request id, which a retry reuses. A provider that answers later
  accepts the request with 202. The client never retries on its own: retries are the
  orchestrator's, with backoff.
  """

  @spec request(struct(), String.t(), %{document_type: String.t(), document: String.t()}) ::
          {:ok, %{status: pos_integer(), body: binary()}} | {:error, :timeout | Exception.t()}
  def request(provider, request_id, holder) do
    url = "#{config(:base_url)}/providers/#{provider.adapter}/profiles"

    body = %{
      request_id: request_id,
      document_type: holder.document_type,
      document: holder.document
    }

    options =
      [json: body, retry: false, decode_body: false, receive_timeout: config(:receive_timeout)] ++
        config(:req_options, [])

    case Req.post(url, options) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, exception} -> {:error, exception}
    end
  end

  defp config(key, default \\ nil),
    do: :fides |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
