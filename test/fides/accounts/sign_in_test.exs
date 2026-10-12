defmodule Fides.Accounts.SignInTest do
  use Fides.DataCase, async: true

  require Ash.Query

  alias Fides.Accounts
  alias Fides.Accounts.StaffToken
  alias Fides.Accounts.StaffUser
  alias Fides.Accounts.Totp
  alias Fides.Factory
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  setup do
    {user, secret} = Factory.staff_user()

    %{
      user: user,
      secret: secret,
      email: to_string(user.email),
      password: Factory.staff_password()
    }
  end

  defp code(secret), do: Totp.code(secret)

  defp tokens(user) do
    subject = AshAuthentication.user_to_subject(user)
    StaffToken |> Ash.Query.filter(subject == ^subject) |> Ash.read!(authorize?: false)
  end

  defp reload(user), do: Ash.get!(StaffUser, user.id, authorize?: false)

  defp expire_lock(user),
    do: Factory.update_staff_user(user, locked_until: DateTime.add(DateTime.utc_now(), -1))

  @tag spec: "ACCT-07"
  test "a password and a current code give a short-lived token", ctx do
    assert {:ok, token, claims} = Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret))

    assert claims["sub"] == "staff_user?id=#{ctx.user.id}"
    assert (claims["exp"] - claims["iat"]) in (15 * 60 - 1)..(15 * 60)
    assert {:ok, %{"jti" => jti}, StaffUser} = AshAuthentication.Jwt.verify(token, :fides)
    assert [%{jti: ^jti}] = tokens(ctx.user)
  end

  @tag spec: "ACCT-07"
  test "without the right code there is no token", ctx do
    for code <- [Factory.wrong_code(ctx.secret), "", "28708", "abcdef", nil] do
      assert Accounts.sign_in(ctx.email, ctx.password, code) == {:error, :authentication_failed}
    end

    assert tokens(ctx.user) == []
  end

  @tag spec: "ACCT-07"
  test "no action signs in, registers or issues a token with the password alone" do
    strategy = AshAuthentication.Info.strategy!(StaffUser, :password)

    refute strategy.sign_in_enabled?
    refute strategy.registration_enabled?
    refute strategy.sign_in_tokens_enabled?

    actions = Enum.map(Ash.Resource.Info.actions(StaffUser), & &1.name)

    for action <- [:sign_in_with_password, :register_with_password, :sign_in_with_token] do
      refute action in actions
    end
  end

  @tag spec: "ACCT-07"
  test "a staff user who never set up the second factor cannot sign in", ctx do
    Factory.update_staff_user(ctx.user, mfa_enrolled_at: nil)

    assert Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret)) ==
             {:error, :authentication_failed}

    assert tokens(ctx.user) == []
  end

  test "a wrong password, an unknown email or malformed input get the same answer", ctx do
    failed = {:error, :authentication_failed}

    assert Accounts.sign_in(ctx.email, "not the password", code(ctx.secret)) == failed
    assert Accounts.sign_in("nobody@fides.test", ctx.password, code(ctx.secret)) == failed
    assert Accounts.sign_in(nil, ctx.password, code(ctx.secret)) == failed
    assert Accounts.sign_in(ctx.email, %{}, code(ctx.secret)) == failed
  end

  test "oversized input is refused before the account is looked up", ctx do
    huge = String.duplicate("a", 2_000)

    for {email, password, code} <- [
          {ctx.email, huge, code(ctx.secret)},
          {ctx.email <> huge, ctx.password, code(ctx.secret)},
          {ctx.email, ctx.password, huge}
        ] do
      assert Accounts.sign_in(email, password, code) == {:error, :authentication_failed}
    end

    assert %{failed_sign_in_attempts: 0} = reload(ctx.user)
  end

  test "the email is matched without regard to case", ctx do
    assert {:ok, _token, _claims} =
             Accounts.sign_in(String.upcase(ctx.email), ctx.password, code(ctx.secret))
  end

  describe "a code works once" do
    test "and using it again counts like a wrong password, not as a guess", ctx do
      code = code(ctx.secret)

      assert {:ok, _token, _claims} = Accounts.sign_in(ctx.email, ctx.password, code)
      assert Accounts.sign_in(ctx.email, ctx.password, code) == {:error, :authentication_failed}
      assert [_one] = tokens(ctx.user)

      for _attempt <- 1..4, do: Accounts.sign_in(ctx.email, ctx.password, code)

      assert %{status: :active, failed_code_attempts: 0, failed_sign_in_attempts: 5} =
               reload(ctx.user)
    end

    test "even for a rival request that read the account before the step was spent", ctx do
      stale = reload(ctx.user)
      assert {:ok, _token, _claims} = Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret))
      spent = reload(ctx.user).totp_last_used_at

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               AuditContext.run([actor: "staff_user:" <> ctx.user.id, reason: "rival"], fn ->
                 stale
                 |> Ash.Changeset.for_update(:claim_totp_step, %{step_start: spent},
                   actor: SystemActor.new(:sign_in)
                 )
                 |> Ash.update()
               end)
    end

    test "and a code accepted early spends its own step", ctx do
      now = System.os_time(:second)

      assert {:ok, _token, _claims} =
               Accounts.sign_in(ctx.email, ctx.password, Totp.code(ctx.secret, now + 30))

      assert reload(ctx.user).totp_last_used_at == Totp.step_start(now + 30)
    end

    test "while an earlier spent step does not refuse the current code", ctx do
      previous = Totp.step_start(System.os_time(:second) - 30)
      Factory.update_staff_user(ctx.user, totp_last_used_at: previous)

      assert {:ok, _token, _claims} = Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret))
    end
  end

  describe "failures" do
    test "five in a row lock sign-in for fifteen minutes", ctx do
      for _attempt <- 1..5, do: Accounts.sign_in(ctx.email, "not the password", code(ctx.secret))

      user = reload(ctx.user)
      assert user.failed_sign_in_attempts == 5
      assert DateTime.diff(user.locked_until, DateTime.utc_now(), :minute) in 14..15

      assert Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret)) ==
               {:error, :authentication_failed}

      expire_lock(ctx.user)

      assert {:ok, _token, _claims} = Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret))
      assert %{failed_sign_in_attempts: 0, locked_until: nil} = reload(ctx.user)
    end

    test "start counting again once a lock is over", ctx do
      for _attempt <- 1..5, do: Accounts.sign_in(ctx.email, "not the password", code(ctx.secret))
      expire_lock(ctx.user)

      for _attempt <- 1..4, do: Accounts.sign_in(ctx.email, "not the password", code(ctx.secret))
      assert %{failed_sign_in_attempts: 4, locked_until: nil} = reload(ctx.user)

      Accounts.sign_in(ctx.email, "not the password", code(ctx.secret))
      assert %{failed_sign_in_attempts: 5, locked_until: %DateTime{}} = reload(ctx.user)
    end

    test "five wrong codes after a right password lock the account until an admin unlocks it",
         ctx do
      for _attempt <- 1..5,
          do: Accounts.sign_in(ctx.email, ctx.password, Factory.wrong_code(ctx.secret))

      assert %{status: :locked, failed_code_attempts: 5} = reload(ctx.user)

      Factory.update_staff_user(ctx.user, locked_until: nil)

      assert Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret)) ==
               {:error, :authentication_failed}

      {admin, _secret} = Factory.staff_user(global_role: :admin)
      {auditor, _secret} = Factory.staff_user(global_role: :auditor)
      AuditContext.put(actor: "staff_user:" <> admin.id, reason: "unlock after failed codes")

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.unlock_staff_user(ctx.user, actor: auditor)

      assert {:ok, %{status: :active}} = Accounts.unlock_staff_user(ctx.user, actor: admin)
      assert {:ok, _token, _claims} = Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret))
    end
  end

  test "the TOTP secret is encrypted, filtered from the evidence and only decrypted to sign in",
       ctx do
    assert {:ok, _token, _claims} = Accounts.sign_in(ctx.email, ctx.password, code(ctx.secret))

    %{rows: [[stored]]} = Repo.query!("SELECT encrypted_totp_secret FROM staff_users")
    ciphertext = Base.decode64!(stored)

    # The vault receives the secret Base64-encoded, so neither form may show through
    for plain <- [ctx.secret, Base.encode64(ctx.secret)], do: refute(ciphertext =~ plain)
    assert Fides.Platform.Vault.decrypt!(ciphertext) =~ Base.encode64(ctx.secret)

    %{rows: [[data]]} =
      Repo.query!("SELECT data FROM carbonite_default.changes WHERE table_name = 'staff_users'")

    assert %{"hashed_password" => "[FILTERED]", "encrypted_totp_secret" => "[FILTERED]"} = data

    assert {:error, error} = Ash.load(ctx.user, :totp_secret, authorize?: false)
    assert Exception.message(error) =~ "only decrypted to check a sign-in code"
  end
end
