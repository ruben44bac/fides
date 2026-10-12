defmodule Fides.Accounts.StaffToken do
  @moduledoc """
  Every token issued to staff, and every revocation. A token is only accepted while
  its row is here and not revoked.

  Not audited: rows churn with every sign-in, and expired ones are swept out in the
  background, with no one to attribute the change to.
  """

  use Fides.Platform.Resource,
    domain: Fides.Accounts,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "staff_tokens"
    repo Fides.Platform.Repo
  end

  audit do
    capture? false
  end

  actions do
    defaults [:read]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  classification do
    attribute :jti, :internal
    attribute :subject, :pseudonymous
    attribute :purpose, :internal
    attribute :expires_at, :internal
    attribute :extra_data, :internal
    attribute :created_at, :public
    attribute :updated_at, :public
  end
end
