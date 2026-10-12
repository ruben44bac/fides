defmodule Fides.Orchestration.OutboxTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  alias Fides.Factory
  alias Fides.Orchestration.Step
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    %{analyst: Factory.scoped_staff("ES", :analyst, admin)}
  end

  defp submit(ctx) do
    Factory.insert(fn ->
      Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)
    end)
  end

  # The versions the enqueued steps of an application were written at
  defp steps(id) do
    for %{args: %{"application_id" => ^id} = args, queue: "orchestration"} <-
          all_enqueued(worker: Step),
        do: args["lock_version"]
  end

  test "every write to an application enqueues one step, with the version it wrote", ctx do
    application = submit(ctx)
    assert steps(application.id) == [1]

    Factory.insert(fn ->
      Origination.transition_application!(application, :validating, 1,
        tenant: "ES",
        actor: @system
      )
    end)

    assert Enum.sort(steps(application.id)) == [1, 2]
  end

  test "a write that rolls back leaves no step", ctx do
    assert {:error, :undone} =
             Repo.transaction(fn ->
               send(self(), {:submitted, submit(ctx).id})
               Repo.rollback(:undone)
             end)

    assert_received {:submitted, id}
    assert steps(id) == []
  end
end
