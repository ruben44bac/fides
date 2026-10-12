defmodule Mix.Tasks.Fides.AdvanceTest do
  # Swaps the global Mix shell, and seeds the same countries as other tests
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Origination
  alias Mix.Tasks.Fides.Advance

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    %{admin: admin, analyst: Factory.scoped_staff("ES", :analyst, admin)}
  end

  defp submit(ctx) do
    Factory.insert(fn ->
      Origination.submit_application!(Factory.submission(), tenant: "ES", actor: ctx.analyst)
    end)
  end

  defp current(application),
    do: Origination.get_application!(application.id, tenant: "ES", authorize?: false)

  test "moves applications to review as the system, under the policy in force", ctx do
    policy = Factory.policy_in_force("ES", ctx.admin)
    first = submit(ctx)
    second = submit(ctx)

    Advance.run([first.id, second.id])

    for application <- [first, second] do
      assert %{state: :in_review, lock_version: 5, policy_version_id: policy_id} =
               current(application)

      assert policy_id == policy.id

      moves =
        "#{application.id}: submitted → validating → awaiting_bank_data → evaluating → " <>
          "in_review, at lock_version 5"

      assert_received {:mix_shell, :info, [^moves]}
    end

    assert %{"actor" => "system:advance", "reason" => "mix fides.advance"} =
             current_carbonite_transaction().meta
  end

  test "continues from where an application is, and stops where only people move it", ctx do
    Factory.policy_in_force("ES", ctx.admin)
    application = submit(ctx)
    Advance.run([application.id])

    # The analyst asks for information, and the answer sends it back to validation
    Factory.insert(fn ->
      application
      |> current()
      |> Origination.transition_application!(:info_requested, 5, %{reason: "payslips"},
        tenant: "ES",
        actor: ctx.analyst
      )
      |> Origination.answer_information_request!(
        %{amount_minor: 900_000, monthly_income_minor: 300_000, expected_version: 6},
        tenant: "ES",
        actor: ctx.analyst
      )
    end)

    Advance.run([application.id])
    assert %{state: :in_review, revision: 2} = current(application)

    moves =
      "#{application.id}: validating → awaiting_bank_data → evaluating → in_review, " <>
        "at lock_version 10"

    assert_received {:mix_shell, :info, [^moves]}

    # Nothing moves when one of the applications cannot
    submitted = submit(ctx)

    assert_raise Mix.Error, ~r/is in_review: the system makes no move/, fn ->
      Advance.run([submitted.id, application.id])
    end

    assert current(submitted).state == :submitted
  end

  test "explains a country without a policy in force, a missing application and the usage",
       ctx do
    application = submit(ctx)

    assert_raise Mix.Error, ~r/No policy version is in force in ES/, fn ->
      Advance.run([application.id])
    end

    assert current(application).state == :submitted

    assert_raise Mix.Error, ~r/No application/, fn -> Advance.run([Ecto.UUID.generate()]) end
    assert_raise Mix.Error, ~r/No application nope/, fn -> Advance.run(["nope"]) end
    assert_raise Mix.Error, ~r/Usage/, fn -> Advance.run([]) end
  end
end
