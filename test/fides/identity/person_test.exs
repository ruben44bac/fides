defmodule Fides.Identity.PersonTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false
  use ExUnitProperties

  alias Fides.Identity
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:test)
  # Letters outside 0-9 and a-f, so they can never show up inside hex-encoded ciphertext
  @holder %{
    document_type: "DNI",
    document: "12345678Z",
    given_names: "Zoila",
    first_surname: "Quintana",
    second_surname: "Sotomayor",
    email: "zoila.quintana@example.com"
  }

  setup do
    Fides.Factory.reference_data()
    AuditContext.put(actor: "system:test", reason: "resolve holders")
    :ok
  end

  defp resolve(attrs, country \\ "ES"),
    do: Identity.resolve_person(attrs, tenant: country, actor: @system)

  test "a holder's name, document and email are stored encrypted and read back" do
    {:ok, person} = resolve(@holder)

    person = Ash.load!(person, [:name, :document, :email], tenant: "ES", actor: @system)

    assert person.document == "12345678Z"
    assert person.email == "zoila.quintana@example.com"

    assert person.name == %{
             given_names: "Zoila",
             first_surname: "Quintana",
             second_surname: "Sotomayor"
           }
  end

  property "resolving a registered document returns the same holder" do
    check all document <- Fides.Identity.Generators.dni(),
              emails <- list_of(string(?a..?z, min_length: 3), min_length: 2, max_length: 4),
              max_runs: 25 do
      ids =
        for email <- emails do
          {:ok, person} = resolve(%{@holder | document: document, email: email <> "@example.com"})
          person.id
        end

      assert Enum.uniq(ids) |> length() == 1
    end
  end

  test "an invalid document or email creates nothing" do
    assert {:error, error} = resolve(%{@holder | document: "12345678A"})
    assert Exception.message(error) =~ "invalid_check_character"

    assert {:error, error} = resolve(%{@holder | email: "not-an-email"})
    assert Exception.message(error) =~ "is not a valid email"

    assert Ash.read!(Fides.Identity.Person, tenant: "ES", actor: @system) == []
  end

  test "the evidence records the holder's country even when the caller did not name it" do
    {:ok, _person} = resolve(@holder, "ES")

    assert %{"country" => "ES", "action" => "Fides.Identity.Person.resolve"} =
             current_carbonite_transaction().meta
  end

  test "no document, name or email appears in clear in the database or the evidence" do
    {:ok, _person} = resolve(@holder)

    %{rows: rows} = Repo.query!("SELECT row_to_json(p)::text FROM people p")
    %{rows: changes} = Repo.query!("SELECT data::text FROM carbonite_default.changes")
    stored = Enum.join(List.flatten(rows ++ changes), "\n")

    assert stored != ""

    for value <- ["12345678Z", "Zoila", "Quintana", "Sotomayor", "zoila.quintana@example.com"] do
      refute String.contains?(String.downcase(stored), String.downcase(value)),
             "#{value} is stored in clear"
    end
  end

  describe "country isolation" do
    test "holders cannot be read or written without a country" do
      assert {:error, %Ash.Error.Invalid{}} = Ash.read(Fides.Identity.Person, actor: @system)
      assert {:error, %Ash.Error.Invalid{}} = Identity.resolve_person(@holder, actor: @system)
    end

    test "a holder cannot use a document type of another country" do
      error =
        assert_raise Postgrex.Error, fn ->
          Fides.Factory.insert(fn ->
            Repo.query!("""
            INSERT INTO people (country_code, document_type, document_hash, email_hash,
                                encrypted_name, encrypted_document, encrypted_email)
            VALUES ('MX', 'DNI', 'h', 'e', 'n', 'd', 'm')
            """)
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == "people_document_type_fkey"
    end

    test "a holder's country cannot change" do
      {:ok, person} = resolve(@holder)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE people SET country_code = 'PT' WHERE id = $1", [
            Ecto.UUID.dump!(person.id)
          ])
        end

      assert error.postgres.constraint == "people_country_code_immutable"
    end
  end

  test "ids are UUIDv7 whether Ash or SQL creates the row" do
    {:ok, person} = resolve(@holder)
    assert <<_::binary-size(14), "7", _::binary>> = person.id

    %{rows: [[id]]} =
      Fides.Factory.insert(fn ->
        Repo.query!("""
        INSERT INTO bank_providers (country_code, name, mode, adapter)
        VALUES ('ES', 'Inserted by SQL', 'sync', 'none') RETURNING id
        """)
      end)

    assert <<_::binary-size(14), "7", _::binary>> = Ecto.UUID.load!(id)
  end
end
