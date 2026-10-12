defmodule FidesWeb.Api.CommandsApiTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import FidesWeb.ApiHelpers

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Origination.CreditApplication
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  # The Spanish policy asks for a countersignature above 50 000 EUR
  @countersign_above 5_000_000

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, auditor_secret} = Factory.staff_user(global_role: :auditor)
    {_analyst, analyst} = staff_token("ES", :analyst, admin)
    {_risk_manager, risk_manager} = staff_token("ES", :risk_manager, admin)
    {_foreign, foreign} = staff_token("MX", :analyst, admin)

    %{
      policy: Factory.policy_in_force("ES", admin),
      analyst: as(conn, analyst),
      risk_manager: as(conn, risk_manager),
      auditor: as(conn, token(auditor, auditor_secret)),
      foreign: as(conn, foreign)
    }
  end

  defp create(ctx, overrides \\ %{}),
    do: ctx.analyst |> command("/api/applications", submission(overrides)) |> json_response(201)

  defp current(%{"id" => id}),
    do: Ash.get!(CreditApplication, id, tenant: "ES", authorize?: false)

  # The system's moves, made as the orchestrator will make them
  defp to_review(ctx, overrides \\ %{}) do
    application = create(ctx, overrides)

    AuditContext.run([actor: "system:test", reason: "evaluate"], fn ->
      application
      |> current()
      |> system_move(:validating)
      |> system_move(:awaiting_bank_data)
      |> system_move(:evaluating)
      |> system_move(:in_review, %{policy_version_id: ctx.policy.id})
    end)

    application
  end

  defp system_move(application, to, extra \\ %{}) do
    Origination.transition_application!(application, to, application.lock_version, extra,
      tenant: "ES",
      actor: SystemActor.new(:orchestrator)
    )
  end

  defp transition(conn, application, to, version, key \\ Ecto.UUID.generate()) do
    command(
      conn,
      "/api/applications/#{application["id"]}/transitions",
      %{to: to, reason: "checked", expected_version: version},
      key
    )
  end

  defp available(conn, application) do
    conn
    |> get("/api/applications/#{application["id"]}/transitions")
    |> json_response(200)
  end

  describe "a transition" do
    test "the life cycle does not allow answers 422 with the allowed ones", ctx do
      application = create(ctx)

      response = transition(ctx.analyst, application, "approved", 1)

      assert %{"errors" => [error]} = json_response(response, 422)

      assert %{"code" => "transition_not_allowed", "meta" => %{"available" => ["cancelled"]}} =
               error

      assert current(application).lock_version == 1
    end

    test "without permission answers 403, and out of the actor's countries 404", ctx do
      application = create(ctx)

      assert %{"errors" => [%{"status" => "403"}]} =
               ctx.auditor |> transition(application, "cancelled", 1) |> json_response(403)

      assert %{"errors" => [%{"status" => "404"}]} =
               ctx.foreign |> transition(application, "cancelled", 1) |> json_response(404)

      assert %{state: :submitted, lock_version: 1} = current(application)
    end

    test "with an old expected version answers 409, and nothing changes", ctx do
      application = create(ctx)
      _cancelled = ctx.analyst |> transition(application, "cancelled", 1) |> json_response(201)
      second = create(ctx)

      assert %{"errors" => [%{"status" => "409", "code" => "stale"}]} =
               ctx.analyst |> transition(second, "cancelled", 7) |> json_response(409)

      assert %{state: :submitted, lock_version: 1} = current(second)
    end

    test "the actor can make exactly the transitions the API lists", ctx do
      application = to_review(ctx, amount_minor: @countersign_above + 1)

      listed = available(ctx.analyst, application)
      assert %{"state" => "in_review", "lock_version" => 5} = listed

      assert Enum.sort(listed["transitions"]) ==
               ~w(cancelled info_requested pending_countersign rejected)

      assert %{"transitions" => []} = available(ctx.risk_manager, application)

      for to <- ~w(approved evaluating in_review validating) do
        assert ctx.analyst |> transition(application, to, 5) |> json_response(422)
      end

      assert %{"state" => "pending_countersign", "lock_version" => 6} =
               ctx.analyst
               |> transition(application, "pending_countersign", 5)
               |> json_response(201)

      assert %{"transitions" => ["approved", "in_review"]} =
               available(ctx.risk_manager, application)
    end
  end

  describe "answering a request for information" do
    test "takes the expected version and an Idempotency-Key, and repeats without effect", ctx do
      application = to_review(ctx)

      _requested =
        ctx.analyst |> transition(application, "info_requested", 5) |> json_response(201)

      path = "/api/applications/#{application["id"]}/revisions"
      answer = %{amount_minor: 900_000, monthly_income_minor: 350_000, expected_version: 6}

      without_version = command(ctx.analyst, path, Map.delete(answer, :expected_version))
      assert %{"errors" => [_error | _]} = json_response(without_version, 422)

      without_key = post(ctx.analyst, path, Jason.encode!(%{data: answer}))

      assert %{"errors" => [%{"code" => "missing_idempotency_key"}]} =
               json_response(without_key, 422)

      first = command(ctx.analyst, path, answer, "answer-1")
      again = command(ctx.analyst, path, answer, "answer-1")

      assert %{"state" => "validating", "revision" => 2, "amount_minor" => 900_000} =
               json_response(first, 201)

      assert body(again) == body(first)
      assert current(application).revision == 2
    end
  end

  describe "retrying" do
    test "takes an Idempotency-Key, and repeating it creates nothing new", ctx do
      application = create(ctx)
      _cancelled = ctx.analyst |> transition(application, "cancelled", 1) |> json_response(201)
      path = "/api/applications/#{application["id"]}/reapply"

      retry = %{
        amount_minor: 800_000,
        monthly_income_minor: 300_000,
        consent_text_version: "2026-10"
      }

      without_key = post(ctx.analyst, path, Jason.encode!(%{data: retry}))

      assert %{"errors" => [%{"code" => "missing_idempotency_key"}]} =
               json_response(without_key, 422)

      first = command(ctx.analyst, path, retry, "retry-1")
      again = command(ctx.analyst, path, retry, "retry-1")

      assert %{"previous_application_id" => previous, "state" => "submitted"} =
               json_response(first, 201)

      assert previous == application["id"]
      assert body(again) == body(first)

      applications = Ash.read!(CreditApplication, tenant: "ES", authorize?: false)
      assert length(applications) == 2
    end
  end
end
