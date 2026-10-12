defmodule Fides.Accounts.SignIn do
  @moduledoc """
  Staff sign-in: the password, then a TOTP code, then a short-lived token.

  Every failure gives the same answer and costs about the same time, so a caller
  never learns whether the email exists, the password was right or the account is
  locked. Failures are counted on the account: five in a row lock sign-in for fifteen
  minutes, and five wrong codes after a right password lock the account until an
  admin unlocks it. Each code works once: its time step is spent with a conditional
  update, so two requests carrying the same code cannot both succeed. A code that was
  already spent was not guessed, so it counts like a wrong password.
  """

  require Ash.Query

  alias AshAuthentication.BcryptProvider
  alias AshAuthentication.Jwt
  alias Fides.Accounts.StaffUser
  alias Fides.Accounts.Totp
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  # Longer input is refused before the lookup, so it costs the same for every email
  @max_input_bytes 1024

  @spec sign_in(term(), term(), term()) ::
          {:ok, String.t(), map()} | {:error, :authentication_failed}
  def sign_in(email, password, code)
      when is_binary(email) and is_binary(password) and is_binary(code) and
             byte_size(email) <= @max_input_bytes and byte_size(password) <= @max_input_bytes and
             byte_size(code) <= @max_input_bytes do
    with {:ok, user} <- fetch_usable(email),
         :ok <- check_password(user, password),
         :ok <- check_code(user, code),
         {:ok, token, claims} <- Jwt.token_for_user(user, %{"purpose" => "user"}) do
      {:ok, token, claims}
    else
      _failure -> {:error, :authentication_failed}
    end
  end

  def sign_in(_email, _password, _code), do: simulate()

  # Unknown, locked or never enrolled: the cost of a password check, nothing recorded
  defp fetch_usable(email) do
    StaffUser
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(actor: actor())
    |> case do
      {:ok, %StaffUser{} = user} -> if usable?(user), do: {:ok, user}, else: simulate()
      _not_found -> simulate()
    end
  end

  defp usable?(user) do
    user.status == :active and not is_nil(user.mfa_enrolled_at) and
      (is_nil(user.locked_until) or DateTime.before?(user.locked_until, DateTime.utc_now()))
  end

  defp simulate do
    BcryptProvider.simulate()
    {:error, :authentication_failed}
  end

  defp check_password(user, password) do
    if BcryptProvider.valid?(password, user.hashed_password),
      do: :ok,
      else: record_failure(user, wrong_code?: false)
  end

  defp check_code(user, code) do
    with {:ok, secret} <- totp_secret(user),
         {:ok, step_start} <- Totp.verify(secret, code, since: user.totp_last_used_at) do
      claim(user, step_start)
    else
      {:error, :spent} -> record_failure(user, wrong_code?: false)
      _wrong_code -> record_failure(user, wrong_code?: true)
    end
  end

  defp totp_secret(user) do
    case Ash.load(user, :totp_secret, actor: actor(), context: %{fides: %{decrypt: :sign_in}}) do
      {:ok, %{totp_secret: secret}} when is_binary(secret) -> {:ok, secret}
      _error -> :error
    end
  end

  # Fails when a rival request spent the step first, or the account was locked meanwhile
  defp claim(user, step_start) do
    AuditContext.run([actor: "staff_user:" <> user.id, reason: "staff sign-in"], fn ->
      user
      |> Ash.Changeset.for_update(:claim_totp_step, %{step_start: step_start}, actor: actor())
      |> Ash.update()
    end)
    |> case do
      {:ok, _user} -> :ok
      {:error, _stale} -> record_failure(user, wrong_code?: false)
    end
  end

  defp record_failure(user, wrong_code?: wrong_code?) do
    AuditContext.run([actor: SystemActor.audit_id(actor()), reason: "failed staff sign-in"], fn ->
      user
      |> Ash.Changeset.for_update(:record_failed_sign_in, %{wrong_code?: wrong_code?},
        actor: actor()
      )
      |> Ash.update!()
    end)

    {:error, :authentication_failed}
  end

  defp actor, do: SystemActor.new(:sign_in)
end
