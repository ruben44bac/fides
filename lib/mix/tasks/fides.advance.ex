defmodule Mix.Tasks.Fides.Advance do
  @shortdoc "Makes the system's moves on applications until they wait for review"

  @moduledoc """
  Makes the system's moves on each application until it waits for an analyst:
  validation, bank data, and an evaluation under the policy version in force in its
  country that asks for review. With it, the review commands of the API can be tried
  before the orchestrator makes these moves on its own.

      mix fides.advance APPLICATION_ID [APPLICATION_ID ...]

  It continues from wherever each application is on that way, so one sent back to
  validation by an answer to a request for information goes back to review. Every
  application is checked before any of them moves. Runs in development and tests only.
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @requirements ["app.start"]

  # The system's next move on the way to review, from each state on it
  @next %{
    submitted: :validating,
    validating: :awaiting_bank_data,
    provider_error: :awaiting_bank_data,
    awaiting_bank_data: :evaluating,
    evaluating: :in_review
  }

  @impl true
  def run([]), do: Mix.raise("Usage: mix fides.advance APPLICATION_ID [APPLICATION_ID ...]")

  def run(ids) do
    if Mix.env() not in [:dev, :test],
      do: Mix.raise("mix fides.advance runs in development and tests only")

    system = SystemActor.new(:advance)
    applications = for id <- Enum.uniq(ids), do: id |> find!(system) |> on_the_way!()

    policies =
      applications
      |> Enum.map(& &1.country_code)
      |> Enum.uniq()
      |> Map.new(&{&1, policy_in_force!(&1, system)})

    AuditContext.run([actor: SystemActor.audit_id(system), reason: "mix fides.advance"], fn ->
      for application <- applications do
        policy = Map.fetch!(policies, application.country_code)
        {moved, states} = advance(application, policy, system, [application.state])

        Mix.shell().info(
          "#{moved.id}: #{Enum.join(states, " → ")}, at lock_version #{moved.lock_version}"
        )
      end
    end)
  end

  defp find!(id, system) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{} = application <- Origination.find_application!(uuid, actor: system) do
      application
    else
      _missing -> Mix.raise("No application #{id}")
    end
  end

  defp on_the_way!(%{state: state} = application) when is_map_key(@next, state), do: application

  defp on_the_way!(application) do
    Mix.raise(
      "Application #{application.id} is #{application.state}: the system makes no move from there"
    )
  end

  defp policy_in_force!(country, system) do
    Fides.Risk.policy_in_force!(tenant: country, actor: system) ||
      Mix.raise("No policy version is in force in #{country}: run mix run priv/repo/seeds.exs")
  end

  defp advance(%{state: state} = application, policy, system, states)
       when is_map_key(@next, state) do
    to = Map.fetch!(@next, state)

    # The evaluation records the policy version it decided with
    extra = if state == :evaluating, do: %{policy_version_id: policy.id}, else: %{}

    application
    |> Origination.transition_application!(to, application.lock_version, extra,
      tenant: application.country_code,
      actor: system
    )
    |> advance(policy, system, [to | states])
  end

  defp advance(application, _policy, _system, states), do: {application, Enum.reverse(states)}
end
