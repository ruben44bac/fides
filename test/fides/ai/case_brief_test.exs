defmodule Fides.AI.CaseBriefTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.AgentFlow
  alias Fides.AI
  alias Fides.AI.CaseBrief.Template
  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.AgentActor

  @ai AgentActor.new(:ai)

  # A model that is down, and one that invents a number the facts do not back
  defmodule Broken do
    @behaviour Fides.AI.Model
    def name, do: "broken"
    def brief(_prompt, _input), do: {:error, :down}
  end

  defmodule Inventing do
    @behaviour Fides.AI.Model
    def name, do: "inventing"

    def brief(_prompt, _input) do
      {:ok,
       %{
         output: %{"summary" => "Income of EUR 99,999.00 covers everything.", "signals" => []},
         tokens_in: 10,
         tokens_out: 5,
         cost_usd: Decimal.new("0.001")
       }}
    end
  end

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    Factory.policy_in_force("ES", admin)
    AgentFlow.provider_answers("ES")
    analyst = Factory.scoped_staff("ES", :analyst, admin)

    # Above 20 000 EUR, Spain's rule sends the application to review
    application =
      Factory.insert(fn ->
        Origination.submit_application!(
          Factory.submission(amount_minor: 2_500_000, monthly_income_minor: 250_000),
          tenant: "ES",
          actor: analyst
        )
      end)

    on_exit(fn -> Application.put_env(:fides, Fides.AI, model: Fides.AI.Models.Mock) end)

    %{analyst: analyst, reviewed: AgentFlow.decided(application)}
  end

  defp with_model(model), do: Application.put_env(:fides, Fides.AI, model: model)

  test "the simulated model writes the brief from the pseudonymized facts, and the run is kept",
       ctx do
    assert %{state: :in_review} = ctx.reviewed
    assert {:ok, run} = AI.brief(ctx.reviewed, @ai)

    assert %{
             capability: :case_brief,
             model: "mock",
             outcome: :model,
             guardrails: :passed,
             tokens_in: 0,
             shadow: false,
             error: nil
           } = run

    assert run.subject_id == ctx.reviewed.id
    assert run.lock_version == ctx.reviewed.lock_version
    assert byte_size(run.prompt_hash) == 32 and byte_size(run.input_hash) == 32

    summary = run.output["summary"]
    assert summary =~ "EUR 25,000.00"
    assert summary =~ "EUR 2,500.00"
    assert summary =~ "score of 720"
    assert summary =~ "sent it to review: amount review threshold"
    assert Enum.any?(run.output["signals"], &(&1 =~ "amount review threshold"))

    # Nothing personal went in or came out
    {:ok, input} = AI.brief_input(ctx.reviewed, @ai)
    refute inspect(input) =~ "Ana"
    refute inspect(input) =~ "@"
    refute summary =~ "@"

    assert {:ok, %{id: id}} = AI.latest_brief("ES", ctx.reviewed.id, ctx.analyst)
    assert id == run.id
  end

  test "when the model fails, or invents, the template stands in and the run says why", ctx do
    with_model(Broken)
    assert {:ok, run} = AI.brief(ctx.reviewed, @ai)
    assert %{model: "broken", outcome: :fallback, guardrails: :skipped, error: ":down"} = run
    {:ok, input} = AI.brief_input(ctx.reviewed, @ai)
    assert run.output == Template.render(input)

    # An invented number is refused, asked again, and refused again
    with_model(Inventing)
    assert {:ok, run} = AI.brief(ctx.reviewed, @ai)
    assert %{model: "inventing", outcome: :fallback, guardrails: :failed} = run
    assert run.error =~ "unbacked_numbers"
    assert run.error =~ "99999.00"
    assert run.output == Template.render(input)
    assert %{tokens_in: 20, tokens_out: 10} = run
    assert Decimal.equal?(run.cost_usd, Decimal.new("0.002"))
  end

  test "the AI reads the case, and moves nothing", ctx do
    assert {:ok, _input} = AI.brief_input(ctx.reviewed, @ai)

    assert {:error, %Ash.Error.Forbidden{}} =
             Origination.transition_application(
               ctx.reviewed,
               :approved,
               ctx.reviewed.lock_version,
               %{reason: "the model says so"},
               tenant: "ES",
               actor: @ai
             )

    # For the AI, the holder does not even exist
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Fides.Identity.holder_document("ES", ctx.reviewed.person_id, @ai)
  end
end
