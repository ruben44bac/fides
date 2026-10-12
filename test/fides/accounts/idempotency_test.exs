defmodule Fides.Accounts.IdempotencyTest do
  use Fides.DataCase, async: true

  alias Fides.Accounts.Idempotency

  setup do
    %{actor: Ash.UUIDv7.generate(), hash: :crypto.hash(:sha256, "a request")}
  end

  # Moves a key's clock back, as if time had passed
  defp age(actor, key, fields) do
    {:ok, actor} = Ecto.UUID.dump(actor)

    Repo.update_all(from(k in "idempotency_keys", where: k.actor_id == ^actor and k.key == ^key),
      set: fields
    )
  end

  test "the first request takes the key; the same request later gets its answer", ctx do
    assert {:new, claimed} = Idempotency.claim(ctx.actor, "k", ctx.hash)
    assert Idempotency.claim(ctx.actor, "k", ctx.hash) == {:error, :busy}

    :ok = Idempotency.complete(claimed, 201, %{"id" => "1"})

    assert {:replay, %{response_status: 201, response_body: %{"id" => "1"}}} =
             Idempotency.claim(ctx.actor, "k", ctx.hash)
  end

  test "another request with the key is refused, and other actors have their own keys", ctx do
    {:new, claimed} = Idempotency.claim(ctx.actor, "k", ctx.hash)
    :ok = Idempotency.complete(claimed, 201, %{})

    assert Idempotency.claim(ctx.actor, "k", :crypto.hash(:sha256, "another")) ==
             {:error, :other_request}

    assert {:new, _claimed} = Idempotency.claim(Ash.UUIDv7.generate(), "k", ctx.hash)
  end

  test "a key freed after a server error, abandoned for a minute or expired is taken again",
       ctx do
    {:new, claimed} = Idempotency.claim(ctx.actor, "freed", ctx.hash)
    :ok = Idempotency.release(claimed)
    assert {:new, _claimed} = Idempotency.claim(ctx.actor, "freed", ctx.hash)

    {:new, _claimed} = Idempotency.claim(ctx.actor, "abandoned", ctx.hash)
    age(ctx.actor, "abandoned", inserted_at: DateTime.add(DateTime.utc_now(), -61))
    assert {:new, _claimed} = Idempotency.claim(ctx.actor, "abandoned", ctx.hash)

    {:new, claimed} = Idempotency.claim(ctx.actor, "expired", ctx.hash)
    :ok = Idempotency.complete(claimed, 201, %{})
    age(ctx.actor, "expired", expires_at: DateTime.add(DateTime.utc_now(), -1))

    assert {:new, _claimed} =
             Idempotency.claim(ctx.actor, "expired", :crypto.hash(:sha256, "new"))
  end
end
