defmodule Mix.Tasks.Fides.Advance do
  @shortdoc "Makes the system's moves on applications until they wait for review"

  @moduledoc """
  Makes the system's moves on each application until it waits for an analyst:
  validation, bank data, the provider's webhook where the data arrives later, and an
  evaluation under the policy version in force in its country that asks for review.
  Each country's life cycle gives the way. With it, the review commands of the API
  can be tried while the orchestrator cannot yet make every one of these moves.

      mix fides.advance APPLICATION_ID [APPLICATION_ID ...]

  It continues from wherever each application is on that way, so one sent back to
  validation by an answer to a request for information goes back to review. When the
  orchestrator moves an application in the meantime, it goes on from there. Every
  application is checked before any of them moves. Runs in development and tests only.
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  alias Fides.Origination
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @requirements ["app.start"]

  # The system's moves toward review, in the order it takes them when it has several
  @way [:validating, :awaiting_bank_data, :awaiting_bank_callback, :evaluating, :in_review]

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

  defp on_the_way!(application) do
    if next(application) do
      application
    else
      Mix.raise(
        "Application #{application.id} is #{application.state}: the system makes no move from there"
      )
    end
  end

  defp next(%{state: :in_review}), do: nil

  defp next(%{country_code: country, state: state}) do
    available = Origination.available_transitions(country, state, :system)
    Enum.find(@way, &(&1 in available))
  end

  defp policy_in_force!(country, system) do
    Fides.Risk.policy_in_force!(tenant: country, actor: system) ||
      Mix.raise("No policy version is in force in #{country}: run mix run priv/repo/seeds.exs")
  end

  defp advance(application, policy, system, states) do
    case next(application) do
      nil ->
        {application, Enum.reverse(states)}

      to ->
        # The evaluation records the policy version it decided with
        extra =
          if application.state == :evaluating, do: %{policy_version_id: policy.id}, else: %{}

        case Origination.transition_application(application, to, application.lock_version, extra,
               tenant: application.country_code,
               actor: system
             ) do
          {:ok, moved} -> advance(moved, policy, system, [to | states])
          {:error, error} -> go_on(application, error, policy, system, states)
        end
    end
  end

  # The orchestrator may have moved the application meanwhile: go on from where it is
  defp go_on(application, error, policy, system, states) do
    case Origination.find_application!(application.id, actor: system) do
      %{lock_version: version} = moved when version != application.lock_version ->
        advance(moved, policy, system, [moved.state | states])

      _unchanged ->
        raise error
    end
  end
end
