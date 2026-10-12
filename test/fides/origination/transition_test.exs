defmodule Fides.Origination.TransitionTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Origination.TransitionNotAllowed
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)
  # The Spanish policy asks for a countersignature above 50 000 EUR
  @countersign_above 5_000_000

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    policy = Factory.policy_in_force("ES", admin)

    actors = %{
      admin: admin,
      policy: policy,
      analyst: Factory.scoped_staff("ES", :analyst, admin),
      risk_manager: Factory.scoped_staff("ES", :risk_manager, admin)
    }

    AuditContext.put(actor: "staff_user:" <> actors.analyst.id, reason: "test commands")
    actors
  end

  defp submit(ctx, overrides \\ %{}) do
    Origination.submit_application!(Factory.submission(overrides),
      tenant: "ES",
      actor: ctx.analyst
    )
  end

  defp move(application, to, actor, extra \\ %{}) do
    Origination.transition_application(
      application,
      to,
      application.lock_version,
      Map.merge(%{reason: "checked"}, extra),
      tenant: "ES",
      actor: actor
    )
  end

  defp move!(application, to, actor, extra \\ %{}) do
    {:ok, application} = move(application, to, actor, extra)
    application
  end

  # The system's way to review: validation, bank data and an evaluation that asks for review
  defp to_review(ctx, overrides \\ %{}) do
    ctx
    |> submit(overrides)
    |> move!(:validating, @system)
    |> move!(:awaiting_bank_data, @system)
    |> move!(:evaluating, @system)
    |> move!(:in_review, @system, %{policy_version_id: ctx.policy.id})
  end

  defp not_allowed({:error, %{errors: errors}}),
    do: Enum.find(errors, &match?(%TransitionNotAllowed{}, &1))

  describe "the life cycle" do
    test "a move it does not allow fails and lists the allowed ones", ctx do
      application = submit(ctx)

      assert %{from: :submitted, to: :approved, available: [:cancelled]} =
               not_allowed(move(application, :approved, ctx.analyst))

      assert %{available: [:validating]} = not_allowed(move(application, :approved, @system))

      assert {:error, error} = move(application, :approved, ctx.analyst)

      assert Exception.message(error) =~
               "cannot move from submitted to approved; allowed: cancelled"
    end

    test "people never make the system's moves, and the system never makes people's", ctx do
      application = to_review(ctx)

      assert %{available: available} = not_allowed(move(application, :evaluating, ctx.analyst))
      refute :evaluating in available

      assert %{available: [:evaluating]} = not_allowed(move(application, :rejected, @system))
      assert {:ok, %{state: :rejected}} = move(application, :rejected, ctx.analyst)
    end

    test "only staff of the country move it, whatever its state", ctx do
      application = submit(ctx)
      foreign = Factory.scoped_staff("MX", :analyst, ctx.admin)

      assert {:error, %Ash.Error.Forbidden{}} = move(application, :cancelled, foreign)
      assert {:error, %Ash.Error.Forbidden{}} = move(application, :validating, foreign)
    end

    test "a person gives a reason, the system need not", ctx do
      application = submit(ctx)

      assert {:error, error} = move(application, :cancelled, ctx.analyst, %{reason: "  "})
      assert Exception.message(error) =~ "is required from a person"

      assert {:ok, %{state: :validating}} =
               move(application, :validating, @system, %{reason: nil})
    end

    test "nothing moves an application out of a final state", ctx do
      cancelled = ctx |> submit() |> move!(:cancelled, ctx.analyst)

      for {to, actor} <- [validating: @system, approved: ctx.analyst, cancelled: ctx.analyst] do
        assert %{from: :cancelled, available: []} = not_allowed(move(cancelled, to, actor))
      end

      assert {:error, error} = move(cancelled, :validating, @system)
      assert Exception.message(error) =~ "allowed: none"
    end

    test "the applicant's side cancels from any state that is not final", ctx do
      assert {:ok, %{state: :cancelled}} = ctx |> submit() |> move(:cancelled, ctx.analyst)
      assert {:ok, %{state: :cancelled}} = ctx |> to_review() |> move(:cancelled, ctx.analyst)
    end
  end

  describe "the expected version" do
    test "a move with another version fails and changes nothing", ctx do
      application = submit(ctx)
      moved = move!(application, :validating, @system)

      assert moved.lock_version == application.lock_version + 1
      assert {:error, %Ash.Error.Invalid{}} = move(application, :cancelled, ctx.analyst)

      current = Origination.get_application!(application.id, tenant: "ES", actor: ctx.analyst)
      assert %{state: :validating} = current
      assert current.lock_version == moved.lock_version
    end
  end

  describe "the policy version" do
    test "only the system records it, when it decides an evaluation", ctx do
      application = ctx |> submit() |> move!(:validating, @system)

      assert {:error, error} =
               move(application, :awaiting_bank_data, @system, %{policy_version_id: ctx.policy.id})

      assert Exception.message(error) =~ "only recorded by the system when it decides"
      assert to_review(ctx).policy_version_id == ctx.policy.id
    end
  end

  describe "countersignature" do
    test "an approval above the threshold goes to a risk manager", ctx do
      application = to_review(ctx, amount_minor: @countersign_above + 1)

      assert %{available: available} = not_allowed(move(application, :approved, ctx.analyst))
      assert :pending_countersign in available

      pending = move!(application, :pending_countersign, ctx.analyst)

      assert %{available: [:cancelled]} = not_allowed(move(pending, :approved, ctx.analyst))
      assert {:ok, %{state: :approved}} = move(pending, :approved, ctx.risk_manager)
    end

    test "a risk manager may also send it back to review", ctx do
      pending =
        ctx
        |> to_review(amount_minor: @countersign_above + 1)
        |> move!(:pending_countersign, ctx.analyst)

      assert {:ok, %{state: :in_review}} = move(pending, :in_review, ctx.risk_manager)
    end

    test "an approval up to the threshold is final", ctx do
      application = to_review(ctx, amount_minor: @countersign_above)

      assert %{available: available} =
               not_allowed(move(application, :pending_countersign, ctx.analyst))

      assert :approved in available
      assert {:ok, %{state: :approved}} = move(application, :approved, ctx.analyst)
    end

    test "without an evaluated policy version, neither approval is possible", ctx do
      application = to_review(ctx)

      without_policy =
        Factory.insert(fn ->
          Repo.query!("UPDATE credit_applications SET policy_version_id = NULL WHERE id = $1", [
            Ecto.UUID.dump!(application.id)
          ])

          Origination.get_application!(application.id, tenant: "ES", actor: ctx.analyst)
        end)

      assert %{available: available} = not_allowed(move(without_policy, :approved, ctx.analyst))
      refute :approved in available or :pending_countersign in available
    end
  end

  describe "answering a request for information" do
    test "adds the next revision, copies its terms and goes back to validation", ctx do
      requested = ctx |> to_review() |> move!(:info_requested, ctx.analyst)

      assert {:ok, answered} =
               Origination.answer_information_request(
                 requested,
                 %{
                   amount_minor: 900_000,
                   monthly_income_minor: 350_000,
                   expected_version: requested.lock_version
                 },
                 tenant: "ES",
                 actor: ctx.analyst
               )

      assert %{state: :validating, revision: 2, amount_minor: 900_000} = answered
      assert answered.monthly_income_minor == 350_000

      assert [%{number: 1, cause: :submitted}, %{number: 2, cause: :info_response} = second] =
               Origination.list_revisions!(
                 tenant: "ES",
                 actor: ctx.analyst,
                 query: [sort: :number]
               )

      assert {second.amount_minor, second.monthly_income_minor} == {900_000, 350_000}
    end

    test "is the only way back to validation", ctx do
      requested = ctx |> to_review() |> move!(:info_requested, ctx.analyst)

      assert {:error, error} = move(requested, :validating, ctx.analyst)
      assert Exception.message(error) =~ "only by answering with the corrected terms"
    end

    test "is refused in any other state", ctx do
      application = to_review(ctx)

      assert {:error, error} =
               Origination.answer_information_request(
                 application,
                 %{
                   amount_minor: 900_000,
                   monthly_income_minor: 350_000,
                   expected_version: application.lock_version
                 },
                 tenant: "ES",
                 actor: ctx.analyst
               )

      assert Exception.message(error) =~ "only an application waiting for information"
    end
  end

  describe "re-evaluating" do
    test "the system sends a reviewed application back to evaluation, with its cause", ctx do
      application = to_review(ctx)

      assert {:error, %Ash.Error.Forbidden{}} =
               Origination.reevaluate_application(
                 application,
                 "new policy",
                 application.lock_version,
                 tenant: "ES",
                 actor: ctx.analyst
               )

      assert {:ok, %{state: :evaluating}} =
               Origination.reevaluate_application(
                 application,
                 "new policy",
                 application.lock_version,
                 tenant: "ES",
                 actor: @system
               )
    end

    test "only from review", ctx do
      application = ctx |> submit() |> move!(:validating, @system)

      assert %{available: _available} =
               not_allowed(
                 Origination.reevaluate_application(
                   application,
                   "new bank data",
                   application.lock_version,
                   tenant: "ES",
                   actor: @system
                 )
               )
    end
  end

  describe "the evidence" do
    test "records the person's reason for a move", ctx do
      application = Factory.insert(fn -> submit(ctx) end)

      {:ok, _cancelled} =
        move(application, :cancelled, ctx.analyst, %{reason: "the holder withdrew"})

      assert %{"reason" => "the holder withdrew", "action" => action} =
               current_carbonite_transaction().meta

      assert action == "Fides.Origination.CreditApplication.transition"
    end
  end
end
