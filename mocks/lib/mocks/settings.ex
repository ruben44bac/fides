defmodule Mocks.Settings do
  @moduledoc """
  The knobs of the simulated providers, from the environment, read on every request
  so a demo can turn them without restarting:

    * `MOCKS_PORT`: where the providers listen (4010).
    * `MOCKS_FIDES_URL`: where Mexico's provider delivers its webhook (http://localhost:4000).
    * `MOCKS_WEBHOOK_SECRET`: what the webhook is signed with; Fides must have the same.
    * `MOCKS_LATENCY_MS`: how long every provider takes to answer (0).
    * `MOCKS_ERROR_RATE`, `MOCKS_TIMEOUT_RATE`, `MOCKS_MALFORMED_RATE`: the share of
      calls, from 0 to 1, that fail with a 500, never answer, or answer something
      malformed (0).
    * `MOCKS_WEBHOOK_DELAY_MS`: how long Mexico's provider waits before delivering (1000).
    * `MOCKS_WEBHOOK_DUPLICATES`: how many extra times each webhook is delivered (0).

  A request can also force one behaviour with the `X-Mock-Scenario` header: `error`,
  `timeout` or `malformed`.
  """

  @spec port() :: pos_integer()
  def port, do: integer("MOCKS_PORT", 4010)

  @spec fides_url() :: String.t()
  def fides_url, do: System.get_env("MOCKS_FIDES_URL", "http://localhost:4000")

  @spec webhook_secret() :: String.t()
  def webhook_secret,
    do: System.get_env("MOCKS_WEBHOOK_SECRET", "fides development provider webhook secret")

  @spec latency_ms() :: non_neg_integer()
  def latency_ms, do: integer("MOCKS_LATENCY_MS", 0)

  @spec webhook_delay_ms() :: non_neg_integer()
  def webhook_delay_ms, do: integer("MOCKS_WEBHOOK_DELAY_MS", 1000)

  @spec webhook_duplicates() :: non_neg_integer()
  def webhook_duplicates, do: integer("MOCKS_WEBHOOK_DUPLICATES", 0)

  @doc "The scenario a call falls into: by the request's header, or by chance at the configured rates."
  @spec scenario(String.t() | nil) :: :ok | :error | :timeout | :malformed
  def scenario(forced) when forced in ["error", "timeout", "malformed"],
    do: String.to_existing_atom(forced)

  def scenario(_none) do
    draw = :rand.uniform()
    error = rate("MOCKS_ERROR_RATE")
    timeout = rate("MOCKS_TIMEOUT_RATE")

    cond do
      draw < error -> :error
      draw < error + timeout -> :timeout
      draw < error + timeout + rate("MOCKS_MALFORMED_RATE") -> :malformed
      true -> :ok
    end
  end

  defp integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp rate(name) do
    case System.get_env(name) do
      nil -> 0.0
      value -> value |> Float.parse() |> elem(0) |> min(1.0) |> max(0.0)
    end
  end
end
