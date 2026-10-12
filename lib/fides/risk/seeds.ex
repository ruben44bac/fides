defmodule Fides.Risk.Seeds do
  @moduledoc """
  Puts each country's first policy version in force, with the thresholds that come
  with the code: one risk manager proposes them and another publishes them. A country
  that already has a version in force is left as it is.
  """

  alias Fides.Platform.AuditContext

  @doc "Both risk managers must have an active scope in every country."
  @spec run(struct(), struct()) :: [Fides.Risk.PolicyVersion.t()]
  def run(proposer, approver) do
    AuditContext.run([actor: "system:seeds", reason: "seed first policy versions"], fn ->
      for country <- Fides.Risk.Engine.countries(), not in_force?(country, approver) do
        {:ok, params} = Fides.Risk.default_params(country)
        draft = Fides.Risk.propose_policy!(params, tenant: country, actor: proposer)
        Fides.Risk.publish_policy!(draft, tenant: country, actor: approver)
      end
    end)
  end

  defp in_force?(country, actor),
    do: Fides.Risk.policy_in_force!(tenant: country, actor: actor) != nil
end
