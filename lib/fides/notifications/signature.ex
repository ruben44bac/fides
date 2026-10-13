defmodule Fides.Notifications.Signature do
  @moduledoc """
  Signs and verifies webhook bodies: `t=<unix seconds>,v1=<HMAC-SHA256 of
  "<seconds>.<body>" in hex>`. A signature older than the tolerance is refused, so a
  captured request cannot be replayed later. Providers that deliver data to Fides sign
  with the same scheme.
  """

  @tolerance_seconds 300

  @spec sign(String.t(), binary(), integer()) :: String.t()
  def sign(secret, body, timestamp) do
    "t=#{timestamp},v1=#{digest(secret, body, timestamp)}"
  end

  @doc "Checks a signature against the body, at `now` (unix seconds)."
  @spec verify(String.t(), String.t() | nil, binary(), integer()) ::
          :ok | {:error, :malformed | :expired | :invalid}
  def verify(secret, header, body, now) when is_binary(header) do
    with {:ok, timestamp, signature} <- parse(header),
         :ok <- fresh(timestamp, now) do
      if Plug.Crypto.secure_compare(signature, digest(secret, body, timestamp)),
        do: :ok,
        else: {:error, :invalid}
    end
  end

  def verify(_secret, _header, _body, _now), do: {:error, :malformed}

  defp parse(header) do
    case Regex.named_captures(~r/^t=(?<t>\d{1,12}),v1=(?<v1>[0-9a-f]{64})$/, header) do
      %{"t" => timestamp, "v1" => signature} -> {:ok, String.to_integer(timestamp), signature}
      nil -> {:error, :malformed}
    end
  end

  defp fresh(timestamp, now) do
    if abs(now - timestamp) <= @tolerance_seconds, do: :ok, else: {:error, :expired}
  end

  defp digest(secret, body, timestamp) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end
end
