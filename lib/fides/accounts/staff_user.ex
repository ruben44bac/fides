defmodule Fides.Accounts.StaffUser do
  @moduledoc """
  A back-office user. Staff have no country of their own: their scopes say where
  they work, unless they hold a global role.

  Staff sign in with a password and a TOTP code, through `Fides.Accounts.SignIn`.
  The TOTP secret is encrypted, and only the sign-in decrypts it.
  """

  use Fides.Platform.Resource,
    domain: Fides.Accounts,
    extensions: [AshAuthentication, AshCloak]

  alias AshAuthentication.Strategy.Password.HashPasswordChange
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.SystemActor

  @lock_after 5
  @lock_minutes 15

  postgres do
    table "staff_users"
    repo Fides.Platform.Repo
  end

  authentication do
    subject_name :staff_user

    tokens do
      enabled? true
      token_resource Fides.Accounts.StaffToken
      signing_secret Fides.Accounts.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
      token_lifetime {15, :minutes}
    end

    strategies do
      # Hashes passwords only. The password alone never signs anyone in: the sign-in
      # checks it together with the second factor.
      password :password do
        identity_field :email
        hashed_password_field :hashed_password
        sign_in_enabled? false
        registration_enabled? false
        sign_in_tokens_enabled? false
      end
    end
  end

  audit do
    filtered [:hashed_password, :encrypted_totp_secret]
  end

  cloak do
    vault Fides.Platform.Vault
    attributes [:totp_secret]
    encrypt_nil? false
    on_decrypt {Fides.Accounts.StaffUser.DecryptGuard, :approve, []}
  end

  actions do
    defaults [:read]

    create :seed do
      description """
      Creates a staff user with a password and an enrolled second factor, or leaves an
      existing user with that email as it is.
      """

      accept [:email, :global_role, :totp_secret]
      upsert? true
      upsert_identity :unique_email
      upsert_fields []

      # At most 256 characters fit in the 1024 bytes the sign-in accepts
      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 12, max_length: 256
      end

      validate present(:totp_secret)
      change {HashPasswordChange, strategy_name: :password}
      change set_attribute(:mfa_enrolled_at, &DateTime.utc_now/0)
    end

    read :get_by_subject do
      description "The active staff user a token names, with the scopes that authorize them now."
      get? true
      argument :subject, :string, allow_nil?: false
      filter expr(status == :active)
      prepare AshAuthentication.Preparations.FilterBySubject
      prepare build(load: [:active_scopes])
    end

    update :claim_totp_step do
      description """
      Spends the time step of an accepted code and clears the failures. Fails when
      that step or a later one is already spent, or the user cannot sign in.
      """

      accept []
      argument :step_start, :utc_datetime_usec, allow_nil?: false

      change filter(
               expr(
                 status == :active and (is_nil(locked_until) or locked_until <= now()) and
                   (is_nil(totp_last_used_at) or totp_last_used_at < ^arg(:step_start))
               )
             )

      change atomic_update(:totp_last_used_at, expr(^arg(:step_start)))
      change set_attribute(:failed_sign_in_attempts, 0)
      change set_attribute(:failed_code_attempts, 0)
      change set_attribute(:locked_until, nil)
    end

    update :record_failed_sign_in do
      description """
      Counts a failed sign-in. Five in a row lock sign-in for fifteen minutes, and the
      count starts again once a lock is over. Five wrong codes in a row after a right
      password lock the account until an admin unlocks it: someone else may know the
      password.
      """

      accept []
      argument :wrong_code?, :boolean, allow_nil?: false, default: false

      # Every expression reads the row as it was before this update
      change atomic_update(
               :failed_sign_in_attempts,
               expr(
                 if not is_nil(locked_until) and locked_until <= now() do
                   1
                 else
                   failed_sign_in_attempts + 1
                 end
               )
             )

      change atomic_update(
               :locked_until,
               expr(
                 cond do
                   not is_nil(locked_until) and locked_until <= now() ->
                     nil

                   failed_sign_in_attempts + 1 >= ^@lock_after ->
                     datetime_add(now(), ^@lock_minutes, :minute)

                   true ->
                     locked_until
                 end
               )
             )

      change atomic_update(
               :failed_code_attempts,
               expr(
                 if ^arg(:wrong_code?), do: failed_code_attempts + 1, else: failed_code_attempts
               )
             )

      change atomic_update(
               :status,
               expr(
                 if ^arg(:wrong_code?) and failed_code_attempts + 1 >= ^@lock_after,
                   do: :locked,
                   else: status
               )
             )
    end

    update :unlock do
      description "Lets a locked staff user sign in again."
      accept []
      change set_attribute(:status, :active)
      change set_attribute(:failed_sign_in_attempts, 0)
      change set_attribute(:failed_code_attempts, 0)
      change set_attribute(:locked_until, nil)
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if SystemActor
      authorize_if {GlobalRole, roles: [:admin, :auditor]}
      authorize_if expr(id == ^actor(:id))
    end

    policy action([:seed, :claim_totp_step, :record_failed_sign_in]) do
      authorize_if SystemActor
    end

    policy action(:unlock) do
      authorize_if {GlobalRole, roles: [:admin]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    # The password strategy checks this flag before the classification sets it
    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :global_role, :atom do
      description "admin or auditor. Nil for staff who only work through country scopes."
      public? true
      constraints one_of: [:admin, :auditor]
    end

    attribute :status, :atom do
      description "locked after too many wrong codes, until an admin unlocks it."
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :locked]
    end

    attribute :totp_secret, :binary

    attribute :mfa_enrolled_at, :utc_datetime_usec do
      description "When the second factor was set up. Without it there is no sign-in."
    end

    attribute :totp_last_used_at, :utc_datetime_usec do
      description "Start of the time step of the last accepted code."
    end

    attribute :failed_sign_in_attempts, :integer do
      description "Failed sign-ins in a row, with a wrong password or a wrong code."
      allow_nil? false
      default 0
    end

    attribute :failed_code_attempts, :integer do
      description "Wrong codes in a row after a right password."
      allow_nil? false
      default 0
    end

    attribute :locked_until, :utc_datetime_usec do
      description "Sign-in is refused until then."
    end

    timestamps()
  end

  classification do
    attribute :id, :pseudonymous
    attribute :email, :internal
    attribute :hashed_password, :internal
    attribute :global_role, :internal
    attribute :status, :internal
    attribute :totp_secret, :internal
    attribute :mfa_enrolled_at, :internal
    attribute :totp_last_used_at, :internal
    attribute :failed_sign_in_attempts, :internal
    attribute :failed_code_attempts, :internal
    attribute :locked_until, :internal
    attribute :inserted_at, :public
    attribute :updated_at, :public
  end

  relationships do
    has_many :active_scopes, Fides.Accounts.StaffScope do
      description "Scopes not revoked, in every country: what authorizes this staff user now."
      destination_attribute :user_id
      read_action :active_for_actor
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
