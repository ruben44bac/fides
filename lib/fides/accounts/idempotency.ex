defmodule Fides.Accounts.Idempotency do
  @moduledoc """
  Claims an idempotency key for a request, so a command runs once per key and actor.

  The first request with a key takes it and runs; its response is kept once it is
  sent. Later requests with the same key and request get that response; with another
  request they are refused. A key whose first request is still running is busy; one
  whose request never finished for a minute, or that expired, is freed and taken
  again.
  """

  require Ash.Query

  alias Fides.Accounts.IdempotencyKey
  alias Fides.Platform.SystemActor

  @abandoned_after_seconds 60

  @type claim ::
          {:new, IdempotencyKey.t()}
          | {:replay, IdempotencyKey.t()}
          | {:error, :other_request | :busy}

  @spec claim(Ecto.UUID.t(), String.t(), binary()) :: claim()
  def claim(actor_id, key, request_hash) do
    with {:error, _taken} <- reserve(actor_id, key, request_hash) do
      actor_id |> get(key) |> resolve(actor_id, key, request_hash)
    end
  end

  @doc "Keeps the response of the request that holds the key."
  @spec complete(IdempotencyKey.t(), pos_integer(), map() | nil) :: :ok
  def complete(claimed, status, body) do
    claimed
    |> Ash.Changeset.for_update(:complete, %{response_status: status, response_body: body},
      actor: actor()
    )
    |> Ash.update!()

    :ok
  end

  @doc "Frees the key, so the request can be tried again."
  @spec release(IdempotencyKey.t()) :: :ok
  def release(claimed) do
    Ash.destroy!(claimed, action: :release, actor: actor())
  end

  defp reserve(actor_id, key, request_hash) do
    IdempotencyKey
    |> Ash.Changeset.for_create(
      :reserve,
      %{actor_id: actor_id, key: key, request_hash: request_hash},
      actor: actor()
    )
    |> Ash.create()
    |> case do
      {:ok, claimed} -> {:new, claimed}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve(nil, actor_id, key, request_hash), do: retry(actor_id, key, request_hash)

  defp resolve(existing, actor_id, key, request_hash) do
    cond do
      stale?(existing) ->
        release(existing)
        retry(actor_id, key, request_hash)

      existing.request_hash != request_hash ->
        {:error, :other_request}

      is_nil(existing.response_status) ->
        {:error, :busy}

      true ->
        {:replay, existing}
    end
  end

  # Taken and freed again by someone else meanwhile: the request is busy, try later
  defp retry(actor_id, key, request_hash) do
    case reserve(actor_id, key, request_hash) do
      {:new, claimed} -> {:new, claimed}
      {:error, _taken} -> {:error, :busy}
    end
  end

  defp stale?(key) do
    now = DateTime.utc_now()

    DateTime.before?(key.expires_at, now) or
      (is_nil(key.response_status) and
         DateTime.diff(now, key.inserted_at) > @abandoned_after_seconds)
  end

  defp get(actor_id, key) do
    IdempotencyKey
    |> Ash.Query.filter(actor_id == ^actor_id and key == ^key)
    |> Ash.read_one!(actor: actor())
  end

  defp actor, do: SystemActor.new(:idempotency)
end
