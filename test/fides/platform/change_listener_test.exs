defmodule Fides.Platform.ChangeListenerTest do
  use ExUnit.Case, async: true

  alias Fides.Platform.ChangeListener

  test "passes a change to the screens showing its country, and nothing it cannot read" do
    Phoenix.PubSub.subscribe(Fides.PubSub, ChangeListener.topic("ES"))

    payload =
      Jason.encode!(%{id: "app-1", country_code: "ES", state: "approved", lock_version: 5})

    assert :ok = ChangeListener.broadcast(payload, Fides.PubSub)

    assert_receive {:application_changed,
                    %{id: "app-1", country_code: "ES", state: "approved", lock_version: 5}}

    assert {:error, :malformed} = ChangeListener.broadcast("not json", Fides.PubSub)
    assert {:error, :malformed} = ChangeListener.broadcast(~s({"id": "x"}), Fides.PubSub)
    refute_receive {:application_changed, _change}
  end

  test "listens on the database from the start of the application" do
    assert is_pid(Process.whereis(ChangeListener))
  end
end
