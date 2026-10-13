defmodule Fides.Accounts.Demo do
  @moduledoc """
  The demo staff: an admin, an auditor, an analyst in Mexico, another in Spain, and
  two risk managers in every country, so one can propose a policy and the other
  approve it.

  They share one password. Each has its own TOTP secret, derived from a seed that
  only development and tests configure, so their codes can be computed here.
  """

  alias Fides.Accounts.Totp

  @countries ~w(ES PT IT MX CO BR)

  @users [
    %{handle: "admin", email: "admin@fides.test", global_role: :admin, scopes: []},
    %{handle: "auditor", email: "auditor@fides.test", global_role: :auditor, scopes: []},
    %{handle: "analyst_mx", email: "analyst.mx@fides.test", scopes: [{"MX", :analyst}]},
    %{handle: "analyst_es", email: "analyst.es@fides.test", scopes: [{"ES", :analyst}]},
    %{
      handle: "risk_manager_1",
      email: "risk.manager1@fides.test",
      scopes: for(country <- @countries, do: {country, :risk_manager})
    },
    %{
      handle: "risk_manager_2",
      email: "risk.manager2@fides.test",
      scopes: for(country <- @countries, do: {country, :risk_manager})
    }
  ]

  @password "fides demo password"

  @doc "Whether this environment has demo staff."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fides, __MODULE__) != nil

  @doc "Every demo staff user, with their global role or their scopes."
  @spec users() :: [map()]
  def users, do: Enum.map(@users, &Map.put_new(&1, :global_role, nil))

  @spec handles() :: [String.t()]
  def handles, do: Enum.map(@users, & &1.handle)

  @doc "The demo staff user with `handle`, or nil."
  @spec user(String.t()) :: map() | nil
  def user(handle), do: Enum.find(users(), &(&1.handle == handle))

  @spec password() :: String.t()
  def password, do: @password

  @doc "The TOTP secret of the demo user `handle`: 20 bytes, as RFC 4226 recommends."
  @spec totp_secret(String.t()) :: binary()
  def totp_secret(handle) do
    seed = :fides |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:totp_seed)
    :crypto.mac(:hmac, :sha, seed, "staff_user totp|" <> handle)
  end

  @doc "The current TOTP code of the demo user `handle`."
  @spec totp_code(String.t()) :: String.t()
  def totp_code(handle), do: Totp.code(totp_secret(handle))

  @doc "How many seconds the current codes stay current."
  @spec seconds_left() :: pos_integer()
  def seconds_left, do: Totp.seconds_left()
end
