defmodule Fides.Origination.CreditApplicationTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Identity
  alias Fides.Origination
  alias Fides.Origination.CreditApplication
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:test)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, _secret} = Factory.staff_user(global_role: :auditor)

    actors = %{
      admin: admin,
      auditor: auditor,
      analyst: Factory.scoped_staff("ES", :analyst, admin),
      risk_manager: Factory.scoped_staff("ES", :risk_manager, admin),
      foreign: Factory.scoped_staff("MX", :analyst, admin)
    }

    AuditContext.put(actor: "staff_user:" <> actors.analyst.id, reason: "submit applications")
    actors
  end

  defp submit(ctx, overrides \\ %{}, actor \\ nil) do
    Origination.submit_application(Factory.submission(overrides),
      tenant: "ES",
      actor: actor || ctx.analyst
    )
  end

  defp applications, do: Ash.read!(CreditApplication, tenant: "ES", authorize?: false)
  defp consents, do: Identity.list_consents!(tenant: "ES", actor: @system)

  defp move(application, to, actor, extra \\ %{}) do
    Origination.transition_application(
      application,
      to,
      application.lock_version,
      Map.merge(%{reason: "test"}, extra),
      tenant: application.country_code,
      actor: actor
    )
  end

  # Runs SQL in a savepoint, so a refused statement leaves the test's transaction usable
  defp raw(sql, params) do
    Factory.insert(fn -> Repo.transaction(fn -> Repo.query!(sql, params) end) end)
  end

  describe "submitting" do
    test "creates the application in submitted with its first revision and holder", ctx do
      before = DateTime.utc_now()
      assert {:ok, application} = submit(ctx)

      assert %{state: :submitted, revision: 1, lock_version: 1, channel: :api} = application
      assert DateTime.compare(application.submitted_at, before) != :lt

      assert {:ok, %{id: person_id}} =
               Identity.get_person(application.person_id, tenant: "ES", actor: @system)

      assert person_id == application.person_id

      assert [revision] = Origination.list_revisions!(tenant: "ES", actor: ctx.analyst)
      assert %{number: 1, cause: :submitted, amount_minor: 1_000_000} = revision
      assert revision.monthly_income_minor == 300_000
      assert byte_size(revision.content_hash) == 32
    end

    test "the state and the submission time are always the server's", ctx do
      for field <- [state: :approved, submitted_at: ~U[2020-01-01 00:00:00Z], revision: 7] do
        assert {:error, %Ash.Error.Invalid{}} = submit(ctx, [field])
      end
    end

    test "records the holder's consent with its purpose, text version, channel and time", ctx do
      {:ok, application} = submit(ctx, channel: :form)

      assert [consent] = consents()
      assert consent.person_id == application.person_id
      assert %{purpose: :credit_evaluation, text_version: "2026-10", channel: :form} = consent
      assert %DateTime{} = consent.accepted_at
    end

    test "amounts that are not positive minor units, or another currency, create nothing", ctx do
      for overrides <- [
            [amount_minor: 0],
            [amount_minor: -5],
            [amount_minor: 10.5],
            [monthly_income_minor: 0],
            [currency: "MXN"],
            [currency: "eur"]
          ] do
        assert {:error, %Ash.Error.Invalid{}} = submit(ctx, overrides), inspect(overrides)
      end

      assert applications() == []
      assert consents() == []
    end

    test "an invalid holder document creates nothing", ctx do
      holder = %{Factory.holder() | document: "12345678A"}

      assert {:error, error} = submit(ctx, holder: holder)
      assert Exception.message(error) =~ "invalid_check_character"
      assert applications() == []
    end

    test "a holder with an application in progress cannot submit another", ctx do
      holder = Factory.holder()
      {:ok, _first} = submit(ctx, holder: holder)

      assert {:error, error} = submit(ctx, holder: holder)
      assert Exception.message(error) =~ "already has an application in progress"
      assert length(applications()) == 1
    end
  end

  describe "retrying" do
    test "a rejected or cancelled application is retried once, by the same holder", ctx do
      {:ok, first} = submit(ctx)
      {:ok, cancelled} = move(first, :cancelled, ctx.analyst)

      retry = %{
        previous_application_id: cancelled.id,
        amount_minor: 800_000,
        monthly_income_minor: 300_000,
        channel: :api,
        consent_text_version: "2026-10"
      }

      assert {:ok, second} = Origination.reapply(retry, tenant: "ES", actor: ctx.analyst)
      assert second.previous_application_id == cancelled.id
      assert second.person_id == cancelled.person_id
      assert %{state: :submitted, revision: 1, amount_minor: 800_000, currency: "EUR"} = second
      assert length(consents()) == 2

      {:ok, _cancelled} = move(second, :cancelled, ctx.analyst)

      assert {:error, error} = Origination.reapply(retry, tenant: "ES", actor: ctx.analyst)
      assert Exception.message(error) =~ "has already been retried"
    end

    test "an application in progress is not retried", ctx do
      {:ok, open} = submit(ctx)

      retry = %{
        previous_application_id: open.id,
        amount_minor: 800_000,
        monthly_income_minor: 300_000,
        channel: :api,
        consent_text_version: "2026-10"
      }

      assert {:error, error} = Origination.reapply(retry, tenant: "ES", actor: ctx.analyst)
      assert Exception.message(error) =~ "only a rejected or cancelled application is retried"

      unknown = %{retry | previous_application_id: Ash.UUIDv7.generate()}
      assert {:error, error} = Origination.reapply(unknown, tenant: "ES", actor: ctx.analyst)
      assert Exception.message(error) =~ "is not an application of the country"
    end

    test "the database refuses a retry pointing to another holder's application", ctx do
      {:ok, first} = submit(ctx)
      {:ok, _cancelled} = move(first, :cancelled, ctx.analyst)
      {:ok, other} = submit(ctx)

      # A final state, so only the retry's key can refuse it
      assert_raise Postgrex.Error, ~r/credit_applications_previous_fkey/, fn ->
        raw(
          """
          INSERT INTO credit_applications (country_code, person_id, previous_application_id,
            currency, amount_minor, monthly_income_minor, state, channel, submitted_at)
          VALUES ('ES', $1, $2, 'EUR', 1, 1, 'cancelled', 'api', now())
          """,
          [Ecto.UUID.dump!(other.person_id), Ecto.UUID.dump!(first.id)]
        )
      end
    end
  end

  describe "the database" do
    test "refuses any change to an application in a final state", ctx do
      {:ok, application} = submit(ctx)
      {:ok, cancelled} = move(application, :cancelled, ctx.analyst)

      assert_raise Postgrex.Error, ~r/credit_applications_final_state/, fn ->
        raw("UPDATE credit_applications SET amount_minor = 1 WHERE id = $1", [
          Ecto.UUID.dump!(cancelled.id)
        ])
      end
    end

    test "counts every change in lock_version, even outside the commands", ctx do
      {:ok, application} = submit(ctx)

      raw("UPDATE credit_applications SET amount_minor = 5 WHERE id = $1", [
        Ecto.UUID.dump!(application.id)
      ])

      assert Ash.get!(CreditApplication, application.id, tenant: "ES", authorize?: false).lock_version ==
               2
    end

    test "refuses to change or delete a revision", ctx do
      {:ok, application} = submit(ctx)
      id = Ecto.UUID.dump!(application.id)

      assert_raise Postgrex.Error, ~r/application_revisions_append_only/, fn ->
        raw("UPDATE application_revisions SET amount_minor = 1 WHERE application_id = $1", [id])
      end

      assert_raise Postgrex.Error, ~r/application_revisions_append_only/, fn ->
        raw("DELETE FROM application_revisions WHERE application_id = $1", [id])
      end
    end

    test "refuses to change or delete a consent", ctx do
      {:ok, _application} = submit(ctx)

      assert_raise Postgrex.Error, ~r/consents_append_only/, fn ->
        raw("DELETE FROM consents", [])
      end
    end
  end

  describe "who may" do
    test "only analysts of the country, or the system, submit", ctx do
      for actor <- [ctx.admin, ctx.auditor, ctx.risk_manager, ctx.foreign] do
        assert {:error, %Ash.Error.Forbidden{}} = submit(ctx, %{}, actor)
      end

      assert {:ok, _application} = submit(ctx, %{}, @system)
    end

    test "staff of the country, admins and auditors read applications, and nobody without a country",
         ctx do
      {:ok, _application} = submit(ctx)

      for actor <- [ctx.analyst, ctx.risk_manager, ctx.admin, ctx.auditor] do
        assert [_application] = Origination.list_applications!(tenant: "ES", actor: actor)
      end

      assert Origination.list_applications!(tenant: "ES", actor: ctx.foreign) == []
      assert {:error, %Ash.Error.Invalid{}} = Origination.list_applications(actor: ctx.admin)
    end
  end
end
