defmodule Fides.Accounts do
  use Ash.Domain,
    otp_app: :fides

  resources do
    resource Fides.Accounts.Token
    resource Fides.Accounts.User
  end
end
