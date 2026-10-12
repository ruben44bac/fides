defmodule Fides.Risk.PolicyVersion.Validations.OtherThanProposer do
  @moduledoc "Refuses to let whoever proposed a version also put it in force."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    approver = context.actor && Map.get(context.actor, :id)

    if approver != nil and approver == changeset.data.proposed_by,
      do:
        {:error,
         field: :approved_by, message: "must be someone other than who proposed the version"},
      else: :ok
  end
end
