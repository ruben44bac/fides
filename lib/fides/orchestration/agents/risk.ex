defmodule Fides.Orchestration.Agents.Risk do
  @moduledoc """
  Decides an application on entering `evaluating`: gathers what Intake found, the bank
  profile and the holder's history into the engine's canonical inputs, and has Risk
  decide with the policy version in force. The decision is kept with everything it
  depended on, and the application moves to approved, rejected or review.

  It sees financial and public data only: never the holder's name, document or
  email. Without a policy version in force, or without a bank profile, the case
  escalates to a person.
  """

  @behaviour Fides.Orchestration.Agent

  alias Fides.Orchestration.Assignment
  alias Fides.Platform.AgentActor

  @tool "risk.evaluate"
  @states %{approve: :approved, reject: :rejected, review: :in_review}

  @impl true
  def name, do: :risk

  @impl true
  def version, do: 1

  @impl true
  def queue(_assignment), do: :risk

  @impl true
  def run(%Assignment{} = assignment) do
    actor = AgentActor.new(:risk)
    country = assignment.country_code

    with {:ok, facts} <- Fides.Orchestration.case_facts(country, assignment.application_id, actor),
         {:ok, profile} <- bank_profile(facts, country, actor),
         {:ok, revision} <- revision(assignment, actor),
         {:ok, rejected_on} <-
           Fides.Origination.last_rejection(
             country,
             assignment.person_id,
             assignment.application_id,
             actor
           ),
         {:ok, decision} <-
           Fides.Risk.decide(
             %{
               country: country,
               application_id: assignment.application_id,
               revision_id: revision.id,
               bank_profile_id: profile.id,
               inputs: inputs(assignment, facts, profile, rejected_on)
             },
             actor: actor
           ) do
      {:advance,
       %{
         to: Map.fetch!(@states, decision.outcome),
         tool: @tool,
         arguments: %{policy_version_id: decision.policy_version_id},
         facts: %{
           decision: %{
             id: decision.id,
             outcome: decision.outcome,
             reason_codes: decision.reason_codes
           }
         }
       }}
    else
      {:error, :no_policy} -> {:escalate, "no policy version is in force in #{country}"}
      {:error, :no_bank_profile} -> {:escalate, "the application has no bank profile"}
      {:error, :no_revision} -> {:escalate, "the application's current revision is missing"}
      {:error, error} -> {:retry, Exception.message(error)}
    end
  end

  defp bank_profile(%{"bank_profile" => %{"id" => id}}, country, actor),
    do: Fides.Banking.get_bank_profile(id, tenant: country, actor: actor)

  defp bank_profile(_facts, _country, _actor), do: {:error, :no_bank_profile}

  defp revision(assignment, actor) do
    case Fides.Origination.revision(
           assignment.country_code,
           assignment.application_id,
           assignment.revision,
           actor
         ) do
      {:ok, nil} -> {:error, :no_revision}
      other -> other
    end
  end

  # Facts come back as JSON: a missing adulthood means the document encodes no birth date
  defp inputs(assignment, facts, profile, rejected_on) do
    %{
      amount_minor: assignment.amount_minor,
      declared_income_minor: assignment.monthly_income_minor,
      observed_income_minor: profile.observed_income_minor,
      total_debt_minor: profile.total_debt_minor,
      score: profile.score,
      income_months: profile.income_months,
      document_valid?: get_in(facts, ["document", "valid"]) == true,
      adult?: get_in(facts, ["adulthood", "adult"]),
      previous_rejection_on: rejected_on,
      evaluated_on: Date.utc_today()
    }
  end
end
