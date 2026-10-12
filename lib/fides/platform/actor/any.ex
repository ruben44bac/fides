defimpl Fides.Platform.Actor, for: Any do
  def global_role(_actor), do: nil
  def country_role(_actor, _country), do: nil
  def countries(_actor, _roles), do: []
end
