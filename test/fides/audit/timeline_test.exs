defmodule Fides.Audit.TimelineTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Audit
  alias Fides.Audit.Timeline
  alias Fides.Factory
  alias Fides.Origination
  alias Fides.Platform.AuditContext

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    %{analyst: Factory.scoped_staff("ES", :analyst, admin)}
  end

  defp submit(holder, ctx) do
    Origination.submit_application!(Factory.submission(holder: holder),
      tenant: "ES",
      actor: ctx.analyst
    )
  end

  defp find(entry, table, op),
    do: Enum.find(entry.changes, &(&1.table == table and &1.op == op))

  describe "from the evidence" do
    # A test runs in one database transaction, so its evidence is one entry, with the
    # meta of the first audited write
    test "tells what was written to the application and its evidence, by whom and why", ctx do
      AuditContext.put(actor: "staff_user:" <> ctx.analyst.id, reason: "a holder applied")
      holder = Factory.holder()
      application = submit(holder, ctx)

      Origination.transition_application!(application, :cancelled, 1, %{reason: "withdrew"},
        tenant: "ES",
        actor: ctx.analyst
      )

      assert [entry] = Audit.timeline(application.id)
      assert %{reason: "a holder applied", country: "ES"} = entry
      assert entry.actor == "staff_user:" <> ctx.analyst.id
      assert is_binary(entry.correlation_id)
      assert %DateTime{} = entry.at

      assert %{data: %{"state" => "submitted", "revision" => 1, "channel" => "api"}} =
               find(entry, "credit_applications", :insert)

      assert %{data: %{"number" => 1, "amount_minor" => 1_000_000, "cause" => "submitted"}} =
               find(entry, "application_revisions", :insert)

      assert %{changed: changed, before: before, data: data} =
               find(entry, "credit_applications", :update)

      assert "state" in changed and "lock_version" in changed
      assert %{"state" => "submitted", "lock_version" => 1} = before
      assert %{"state" => "cancelled", "lock_version" => 2} = data

      # Nothing personal, and no table outside the story
      text = inspect(entry)
      refute text =~ holder.document
      refute text =~ holder.given_names
      refute text =~ holder.email

      assert Enum.map(entry.changes, & &1.table) |> Enum.uniq() |> Enum.sort() ==
               ["application_revisions", "credit_applications"]
    end

    test "leaves out what happened to other applications", ctx do
      AuditContext.put(actor: "staff_user:" <> ctx.analyst.id, reason: "two holders applied")
      one = submit(Factory.holder(), ctx)
      other = submit(Factory.holder(), ctx)

      Origination.transition_application!(other, :cancelled, 1, %{reason: "withdrew"},
        tenant: "ES",
        actor: ctx.analyst
      )

      assert [%{changes: changes}] = Audit.timeline(one.id)

      assert Enum.map(changes, &{&1.table, &1.op}) |> Enum.sort() ==
               [{"application_revisions", :insert}, {"credit_applications", :insert}]

      assert Audit.timeline(Ash.UUIDv7.generate()) == []
    end
  end

  describe "entries" do
    defp transaction(id, at, meta),
      do: %Carbonite.Transaction{id: id, xact_id: id, inserted_at: at, meta: meta}

    defp change(id, transaction, table, op, pk, data, changed \\ []) do
      %Carbonite.Change{
        id: id,
        op: op,
        table_prefix: "public",
        table_name: table,
        table_pk: [pk],
        data: data,
        changed: changed,
        transaction_id: transaction.id,
        transaction: transaction
      }
    end

    test "one entry per transaction, in order, with each row's earlier values" do
      first =
        transaction(1, ~U[2026-10-12 10:00:00.000000Z], %{
          "actor" => "staff_user:1",
          "reason" => "backoffice",
          "action" => "Fides.Origination.CreditApplication.submit"
        })

      later =
        transaction(2, ~U[2026-10-12 10:00:05.000000Z], %{
          "actor" => "system:orchestrator",
          "reason" => "intake proposed awaiting_bank_data"
        })

      application = %{
        "id" => "app",
        "state" => "submitted",
        "lock_version" => 1,
        "person_id" => "p"
      }

      changes = [
        change(
          3,
          later,
          "credit_applications",
          :update,
          "app",
          %{application | "state" => "awaiting_bank_data", "lock_version" => 3},
          ["state", "lock_version", "updated_at"]
        ),
        change(1, first, "credit_applications", :insert, "app", application),
        change(2, first, "application_revisions", :insert, "rev", %{
          "number" => 1,
          "amount_minor" => 100,
          "content_hash" => "secret"
        })
      ]

      assert [
               %{id: 1, actor: "staff_user:1", action: action, changes: [created, revision]},
               %{id: 2, reason: "intake proposed awaiting_bank_data", changes: [moved]}
             ] = Timeline.entries(changes)

      assert action == "Fides.Origination.CreditApplication.submit"

      assert %{op: :insert, data: %{"state" => "submitted", "lock_version" => 1}, before: %{}} =
               created

      refute Map.has_key?(created.data, "person_id")

      assert %{table: "application_revisions", data: %{"number" => 1, "amount_minor" => 100}} =
               revision

      refute Map.has_key?(revision.data, "content_hash")

      assert %{
               op: :update,
               changed: ["state", "lock_version"],
               before: %{"state" => "submitted", "lock_version" => 1},
               data: %{"state" => "awaiting_bank_data", "lock_version" => 3}
             } = moved
    end
  end
end
