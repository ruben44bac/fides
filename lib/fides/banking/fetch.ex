defmodule Fides.Banking.Fetch do
  @moduledoc false
  # Asks the country's provider for a holder's profile and records the call. A profile
  # is kept normalized and masked, with the hash of the answer; the answer itself and
  # the document never are.

  alias Fides.Banking.Adapters
  alias Fides.Banking.Client
  alias Fides.Platform.BlindIndex

  require Ash.Query

  @spec run(String.t(), Ecto.UUID.t(), map(), String.t(), term()) ::
          {:ok, struct()} | {:accepted, String.t()} | {:error, String.t()}
  def run(country, application_id, holder, request_id, actor) do
    opts = [tenant: country, actor: actor]

    case Fides.Banking.list_bank_providers!(%{}, Keyword.put(opts, :query, active())) do
      [provider | _others] ->
        started = System.monotonic_time(:millisecond)
        result = Client.request(provider, request_id, holder)

        call = %{
          provider_id: provider.id,
          application_id: application_id,
          request_id: request_id,
          request_hash: request_hash(country, provider, request_id, holder),
          latency_ms: System.monotonic_time(:millisecond) - started,
          attempt: previous_attempts(request_id, opts) + 1
        }

        answer(result, provider, call, opts)

      [] ->
        {:error, "#{country} has no active bank provider"}
    end
  end

  defp answer({:ok, %{status: 200, body: body}}, provider, call, opts) do
    call = Map.merge(call, %{http_status: 200, response_hash: hash(body)})

    case Adapters.parse(provider.adapter, body) do
      {:ok, profile} ->
        exchange = record!(Map.put(call, :status, :ok), opts)
        {:ok, profile!(profile, exchange, hash(body), opts)}

      {:error, {:malformed, field}} ->
        record!(Map.merge(call, %{status: :error, error: "malformed #{field}"}), opts)
        {:error, "the provider's answer is malformed: #{field}"}

      {:error, :unknown_adapter} ->
        record!(Map.merge(call, %{status: :error, error: "unknown adapter"}), opts)
        {:error, "the provider's adapter is unknown"}
    end
  end

  defp answer({:ok, %{status: 202, body: body}}, _provider, call, opts) do
    record!(
      Map.merge(call, %{status: :pending, http_status: 202, response_hash: hash(body)}),
      opts
    )

    {:accepted, call.request_id}
  end

  defp answer({:ok, %{status: status, body: body}}, _provider, call, opts) do
    record!(
      Map.merge(call, %{
        status: :error,
        http_status: status,
        response_hash: hash(body),
        error: "answered #{status}"
      }),
      opts
    )

    {:error, "the provider answered #{status}"}
  end

  defp answer({:error, :timeout}, _provider, call, opts) do
    record!(Map.put(call, :status, :timeout), opts)
    {:error, "the provider did not answer in time"}
  end

  defp answer({:error, exception}, _provider, call, opts) do
    record!(Map.merge(call, %{status: :error, error: Exception.message(exception)}), opts)
    {:error, "the provider could not be reached"}
  end

  defp active, do: Ash.Query.filter(Fides.Banking.BankProvider, status == :active)

  defp previous_attempts(request_id, opts) do
    Fides.Banking.ProviderExchange
    |> Ash.Query.filter(request_id == ^request_id)
    |> Ash.count!(opts)
  end

  defp record!(call, opts), do: Fides.Banking.record_provider_exchange!(call, opts)

  defp profile!(profile, exchange, payload_hash, opts) do
    profile
    |> Map.from_struct()
    |> Map.merge(%{
      provider_id: exchange.provider_id,
      application_id: exchange.application_id,
      exchange_id: exchange.id,
      origin: :live,
      payload_hash: payload_hash
    })
    |> Fides.Banking.record_bank_profile!(opts)
  end

  # The document enters only through its keyed hash
  defp request_hash(country, provider, request_id, holder) do
    hash(Enum.join([request_id, provider.id, BlindIndex.document(country, holder.document)], ":"))
  end

  defp hash(data), do: :crypto.hash(:sha256, data)
end
