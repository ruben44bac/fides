defmodule Fides.Notifications.NoticesTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use Oban.Testing, repo: Fides.Platform.Repo

  import Swoosh.TestAssertions

  alias Fides.Factory
  alias Fides.Notifications
  alias Fides.Notifications.Notify
  alias Fides.Orchestration.Step
  alias Fides.Origination
  alias Fides.Platform.AgentActor
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)

    %{
      analyst: Factory.scoped_staff("ES", :analyst, admin),
      mexican: Factory.scoped_staff("MX", :analyst, admin)
    }
  end

  # The system's way to a rejection; in Mexico the bank data arrives by webhook
  defp rejected(submission, country, analyst) do
    bank_data = if country == "MX", do: [:awaiting_bank_callback], else: []
    way = [:validating, :awaiting_bank_data] ++ bank_data ++ [:evaluating, :rejected]

    Factory.insert(fn ->
      application = Origination.submit_application!(submission, tenant: country, actor: analyst)

      Enum.reduce(way, application, fn to, moved ->
        Origination.transition_application!(moved, to, moved.lock_version,
          tenant: country,
          actor: @system
        )
      end)
    end)
  end

  defp step(application) do
    perform_job(Step, %{
      application_id: application.id,
      country_code: application.country_code,
      lock_version: application.lock_version
    })
  end

  test "a change notifies the applicant once, in the language of their country", ctx do
    holder = Factory.holder()
    application = rejected(Factory.submission(holder: holder), "ES", ctx.analyst)

    assert :ok = step(application)
    assert :ok = step(application)

    assert [notification] = Notifications.list_notifications!(tenant: "ES", actor: @system)

    assert %{
             template: :rejected,
             language: "es",
             channel: :email,
             state: :pending,
             lock_version: 5
           } =
             notification

    assert [job] = all_enqueued(worker: Notify)
    assert :ok = perform_job(Notify, job.args)

    assert_email_sent(fn email ->
      assert [{_name, address}] = email.to
      assert address == holder.email
      assert email.subject == "Tu solicitud de crédito no fue aprobada"
      assert email.text_body =~ String.slice(application.id, 0, 8)
      refute email.text_body =~ holder.given_names
      true
    end)

    assert [%{state: :sent, sent_at: %DateTime{}}] =
             Notifications.list_notifications!(tenant: "ES", actor: @system)
  end

  test "each country's notices come in its language" do
    assert Enum.map(~w(ES PT IT MX CO BR), &Notifications.language/1) == ~w(es pt it es es pt)

    for template <- [:info_requested, :approved, :rejected], language <- ~w(es pt it) do
      {subject, body} =
        Fides.Notifications.Templates.render(template, language, Ash.UUIDv7.generate())

      assert subject != "" and body =~ ~r/\w/
    end
  end

  test "the mail asks Identity for the address; the notifier itself never gets it", ctx do
    application = rejected(Factory.mexican_submission(), "MX", ctx.mexican)

    assert {:ok, "gloria@example.com"} =
             Fides.Identity.holder_email("MX", application.person_id, AgentActor.new(:mailer))

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Fides.Identity.holder_email("MX", application.person_id, AgentActor.new(:notifier))
  end
end
