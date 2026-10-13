defmodule Fides.Platform.ChangeListener do
  @moduledoc """
  Hears, on a connection of its own to the database, the notification every change
  to an application sends, and passes it to the screens of this node that show that
  country's applications. The connection is direct, never through a pooler, since
  listening needs a session of its own.
  """

  use GenServer

  @channel "credit_applications"
  @connection_keys [:hostname, :port, :username, :password, :database, :ssl, :socket_options]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The topic of a country's changes."
  @spec topic(String.t()) :: String.t()
  def topic(country), do: "applications:" <> country

  @doc "Passes a notification's payload to the screens showing its country."
  @spec broadcast(String.t(), atom()) :: :ok | {:error, term()}
  def broadcast(payload, pubsub) do
    case Jason.decode(payload) do
      {:ok, %{"country_code" => country, "id" => id, "state" => state, "lock_version" => version}} ->
        change = %{id: id, country_code: country, state: state, lock_version: version}
        Phoenix.PubSub.local_broadcast(pubsub, topic(country), {:application_changed, change})

      _other ->
        {:error, :malformed}
    end
  end

  @impl true
  def init(opts) do
    config = Fides.Platform.Repo.config() |> Keyword.take(@connection_keys)
    {:ok, connection} = Postgrex.Notifications.start_link(config ++ [auto_reconnect: true])
    {:ok, _ref} = Postgrex.Notifications.listen(connection, @channel)
    {:ok, %{connection: connection, pubsub: Keyword.get(opts, :pubsub, Fides.PubSub)}}
  end

  @impl true
  def handle_info({:notification, _connection, _ref, @channel, payload}, state) do
    broadcast(payload, state.pubsub)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
