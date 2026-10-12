defmodule Fides.Platform.AuditContext do
  @moduledoc """
  Who is writing, and why.

  The context lives in the process dictionary. When Ash opens a transaction, the Repo
  calls `begin_transaction/2`, which inserts the Carbonite transaction carrying this
  context as its `meta`. Without a context nothing is inserted, and Carbonite's trigger
  rejects any write to an audited table: writes fail closed.

  The actor is a pseudonymous string such as `"system:seeds"` or `"staff_user:<id>"`.
  It must never contain PII.
  """

  @enforce_keys [:actor, :reason, :correlation_id]
  defstruct [:actor, :reason, :correlation_id, :action, :country, :traceparent]

  @type t :: %__MODULE__{
          actor: String.t(),
          reason: String.t(),
          correlation_id: String.t(),
          action: String.t() | nil,
          country: String.t() | nil,
          traceparent: String.t() | nil
        }

  @key {__MODULE__, :context}
  @suppressed_key {__MODULE__, :suppressed}

  @doc """
  Builds a context. `:actor` and `:reason` are required; `:correlation_id` is
  generated when missing.
  """
  @spec new(keyword() | map()) :: t()
  def new(fields) do
    fields = Map.new(fields)

    for key <- [:actor, :reason] do
      case Map.get(fields, key) do
        value when is_binary(value) and value != "" ->
          :ok

        other ->
          raise ArgumentError, "audit context needs a non-empty #{key}, got: #{inspect(other)}"
      end
    end

    fields = Map.put_new_lazy(fields, :correlation_id, &Ash.UUIDv7.generate/0)
    struct!(__MODULE__, fields)
  end

  @doc "Sets the context for the current process."
  @spec put(t() | keyword() | map()) :: :ok
  def put(%__MODULE__{} = context) do
    Process.put(@key, context)
    :ok
  end

  def put(fields), do: put(new(fields))

  @doc "Returns the current context, or nil."
  @spec get() :: t() | nil
  def get, do: Process.get(@key)

  @doc "Removes the context from the current process."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc """
  Runs `fun` with `context` and restores the previous context afterwards.
  Fields not given are inherited from the current context.
  """
  @spec run(t() | keyword() | map(), (-> result)) :: result when result: var
  def run(%__MODULE__{} = context, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, context)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  def run(fields, fun) do
    inherited =
      case get() do
        nil -> %{}
        current -> Map.from_struct(current)
      end

    run(new(Map.merge(inherited, Map.new(fields))), fun)
  end

  @doc false
  # Test factories only: Ash transactions opened inside `fun` insert no Carbonite
  # transaction, even if code inside sets its own context. Capture must be switched
  # off in the database as well.
  def suppress(fun) when is_function(fun, 0) do
    previous = Process.put(@suppressed_key, true)

    try do
      fun.()
    after
      if previous,
        do: Process.put(@suppressed_key, previous),
        else: Process.delete(@suppressed_key)
    end
  end

  @doc false
  # Called by Fides.Platform.Repo.on_transaction_begin/1, inside the new transaction.
  def begin_transaction(repo, reason) do
    case {Process.get(@suppressed_key), get()} do
      {nil, %__MODULE__{} = context} ->
        {:ok, _transaction} = Carbonite.insert_transaction(repo, %{meta: meta(context, reason)})
        :ok

      _suppressed_or_no_context ->
        :ok
    end
  end

  @doc """
  The Carbonite meta for `context`. String keys only: Carbonite stores it as jsonb.
  """
  @spec meta(t(), map()) :: %{String.t() => String.t() | nil}
  def meta(%__MODULE__{} = context, reason \\ %{}) do
    %{
      "actor" => context.actor,
      "action" => context.action || action_name(reason),
      "reason" => context.reason,
      "country" => context.country || reason_field(reason, :tenant),
      "correlation_id" => context.correlation_id,
      "traceparent" => context.traceparent,
      "code_sha" => Fides.Platform.Build.code_sha()
    }
  end

  defp action_name(reason) do
    resource = reason_field(reason, :resource)

    action =
      case reason_field(reason, :action) do
        %{name: name} -> name
        name -> name
      end

    if resource && action, do: "#{inspect(resource)}.#{action}"
  end

  defp reason_field(reason, key) when is_map(reason) do
    case Map.get(reason, :metadata) do
      metadata when is_map(metadata) -> Map.get(metadata, key)
      metadata when is_list(metadata) -> Keyword.get(metadata, key)
      _ -> nil
    end
  end

  defp reason_field(_reason, _key), do: nil

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
