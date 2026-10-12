defimpl Fides.Platform.Actor, for: Fides.Accounts.StaffUser do
  use Boundary, classify_to: Fides.Accounts

  def global_role(user), do: user.global_role

  # A global role never acts through country scopes, and scopes that were not loaded
  # count as none
  def country_role(%{global_role: nil, active_scopes: scopes}, country) when is_list(scopes),
    do: Enum.find_value(scopes, &(&1.country_code == country and &1.role))

  def country_role(_user, _country), do: nil

  def countries(%{global_role: nil, active_scopes: scopes}, roles) when is_list(scopes),
    do: for(scope <- scopes, scope.role in roles, do: scope.country_code)

  def countries(_user, _roles), do: []
end
