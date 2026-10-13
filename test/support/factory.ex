defmodule Fides.Factory do
  @moduledoc """
  Builds test fixtures without leaving evidence. This is the only place where
  Carbonite capture is switched off: everywhere else, writing without an
  audit context fails.
  """

  use Boundary, check: [in: false, out: false]

  import Ecto.Query, only: [from: 2]

  alias Fides.Platform.AuditContext
  alias Fides.Platform.Repo
  alias Fides.Platform.SystemActor

  @doc """
  Runs `fun` with capture switched off for the current transaction, then restores
  each table's own mode. No Carbonite transaction is inserted, so the next audited
  action in the test still records its own meta.
  """
  def insert(fun) when is_function(fun, 0) do
    AuditContext.suppress(fn ->
      :ok = Carbonite.override_mode(Repo, to: :ignore)

      try do
        fun.()
      after
        Repo.query!("SET LOCAL carbonite_default.override_mode TO DEFAULT")
      end
    end)
  end

  @doc "Seeds the six launch countries without evidence."
  def countries do
    insert(&Fides.Countries.Seeds.run/0)
  end

  @doc """
  Seeds the countries with their document types, bank providers and life cycles,
  without evidence.
  """
  def reference_data do
    insert(fn ->
      Fides.Countries.Seeds.run()
      Fides.Identity.Seeds.run()
      Fides.Banking.Seeds.run()
      Fides.Origination.Seeds.run()
    end)
  end

  @staff_password "a staff password"

  @doc "The password of every staff user built here."
  def staff_password, do: @staff_password

  @doc """
  Creates a staff user without evidence, enrolled with `:totp_secret` (default: a new
  one). Returns the user and their secret.
  """
  def staff_user(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          email: "staff-#{System.unique_integer([:positive])}@fides.test",
          password: @staff_password,
          totp_secret: NimbleTOTP.secret()
        },
        Map.new(attrs)
      )

    user =
      insert(fn ->
        Fides.Accounts.seed_staff_user!(attrs, actor: SystemActor.new(:factory))
      end)

    {user, attrs.totp_secret}
  end

  @doc "A well-formed TOTP code that `secret` accepts in none of the steps around now."
  def wrong_code(secret) do
    now = System.os_time(:second)
    accepted = for step <- -2..2, do: Fides.Accounts.Totp.code(secret, now + step * 30)
    Enum.find(~w(000000 000001 000002 000003 000004 000005), &(&1 not in accepted))
  end

  @doc "Gives `user` a `role` in `country`, granted by `admin`, without evidence."
  def scope(user, country, role, admin) do
    insert(fn -> Fides.Accounts.grant_scope!(user.id, role, tenant: country, actor: admin) end)
  end

  @doc """
  A staff user with `role` in each of `countries`, granted by `admin`, loaded as
  policies see them.
  """
  def scoped_staff(countries, role, admin) do
    {user, _secret} = staff_user()
    for country <- List.wrap(countries), do: scope(user, country, role, admin)
    Fides.Accounts.load_actor(user)
  end

  @doc "A valid Spanish DNI for `number`, so each test can have its own holders."
  def dni(number) do
    digits = number |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0")
    digits <> Fides.Identity.Documents.ES.control_letter(digits)
  end

  @doc "A Spanish holder's data, as a submission carries it."
  def holder(number \\ System.unique_integer([:positive])) do
    %{
      document_type: "DNI",
      document: dni(number),
      given_names: "Ana",
      first_surname: "Ruiz",
      email: "ana.#{number}@example.com"
    }
  end

  @doc "A Spanish application's submission, with `overrides`."
  def submission(overrides \\ %{}) do
    Map.merge(
      %{
        amount_minor: 1_000_000,
        monthly_income_minor: 300_000,
        currency: "EUR",
        channel: :api,
        holder: holder(),
        consent_text_version: "2026-10"
      },
      Map.new(overrides)
    )
  end

  @doc "A Mexican holder, Gloria Hernández García, born in 1956: her CURP matches her data."
  def mexican_holder do
    %{
      document_type: "CURP",
      document: "HEGG560427MVZRRL04",
      given_names: "Gloria",
      first_surname: "Hernández",
      second_surname: "García",
      birth_date: ~D[1956-04-27],
      sex: :female,
      email: "gloria@example.com"
    }
  end

  @doc "A Mexican application's submission, with `overrides`."
  def mexican_submission(overrides \\ %{}) do
    Map.merge(
      %{
        amount_minor: 10_000_000,
        monthly_income_minor: 3_000_000,
        currency: "MXN",
        channel: :api,
        holder: mexican_holder(),
        consent_text_version: "2026-10"
      },
      Map.new(overrides)
    )
  end

  @doc """
  The country's first policy version in force, without evidence: proposed and
  published by two risk managers of the country.
  """
  def policy_in_force(country, admin) do
    proposer = scoped_staff(country, :risk_manager, admin)
    approver = scoped_staff(country, :risk_manager, admin)
    {:ok, params} = Fides.Risk.default_params(country)

    insert(fn ->
      params
      |> Fides.Risk.propose_policy!(tenant: country, actor: proposer)
      |> Fides.Risk.publish_policy!(tenant: country, actor: approver)
    end)
  end

  @doc "Overwrites columns of a staff user's row without evidence, for states no action sets."
  def update_staff_user(user, columns) do
    {:ok, id} = Ecto.UUID.dump(user.id)
    insert(fn -> Repo.update_all(from(u in "staff_users", where: u.id == ^id), set: columns) end)
  end
end
