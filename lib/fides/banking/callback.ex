defmodule Fides.Banking.Callback do
  @moduledoc """
  A provider's answer that arrives later, through its signed webhook: finds the
  country's asynchronous provider, checks the signature, and reads the event's
  identity and the profile. The body itself is never kept, only its hash.
  """

  require Ash.Query

  alias Fides.Banking.Adapters
  alias Fides.Banking.BankProvider
  alias Fides.Notifications.Signature

  @type parsed :: %{
          envelope: %{event_id: String.t(), sequence: non_neg_integer(), request_id: String.t()},
          profile: Adapters.Profile.t(),
          payload_hash: binary()
        }

  @spec verify(String.t(), String.t() | nil, binary(), integer()) ::
          {:ok, BankProvider.t(), parsed()}
          | {:error, BankProvider.t(), {:signature, atom()} | {:malformed, atom()}}
          | {:error, :no_provider}
  def verify(country, signature, body, now \\ System.os_time(:second)) do
    with {:ok, provider} <- async_provider(country) do
      with :ok <- check_signature(signature, body, now),
           {:ok, envelope} <- Adapters.envelope(provider.adapter, body),
           {:ok, profile} <- Adapters.parse(provider.adapter, body) do
        {:ok, provider, %{envelope: envelope, profile: profile, payload_hash: hash(body)}}
      else
        {:error, :unknown_adapter} -> {:error, provider, {:malformed, :adapter}}
        {:error, reason} -> {:error, provider, reason}
      end
    end
  end

  @doc "The event's identity when the body allows it, for the record of an event that failed."
  @spec envelope(BankProvider.t(), binary()) :: map()
  def envelope(provider, body) do
    case Adapters.envelope(provider.adapter, body) do
      {:ok, envelope} ->
        envelope

      {:error, _reason} ->
        %{event_id: hash(body) |> Base.encode16(case: :lower), sequence: nil, request_id: nil}
    end
  end

  @spec hash(binary()) :: binary()
  def hash(body), do: :crypto.hash(:sha256, body)

  defp async_provider(country) do
    BankProvider
    |> Ash.Query.filter(mode == :async and status == :active)
    |> Ash.read_one(tenant: country, authorize?: false)
    |> case do
      {:ok, %BankProvider{} = provider} -> {:ok, provider}
      _none_or_invalid_country -> {:error, :no_provider}
    end
  end

  defp check_signature(signature, body, now) do
    case Signature.verify(secret(), signature, body, now) do
      :ok -> :ok
      {:error, reason} -> {:error, {:signature, reason}}
    end
  end

  defp secret, do: :fides |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:secret)
end
