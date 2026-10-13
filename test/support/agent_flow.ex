defmodule Fides.AgentFlow do
  @moduledoc """
  Drives an application through the agents in tests, one agent at a time, as the
  orchestrator would: the country's bank provider answers every call with its recorded
  answer, and each agent runs as its job, leaving its evidence.
  """

  use Boundary, check: [in: false, out: false]

  alias Fides.Factory
  alias Fides.Orchestration.AgentJob
  alias Fides.Origination
  alias Fides.Platform.SystemActor

  @system SystemActor.new(:orchestrator)
  @answers %{
    "ES" => "es.json",
    "PT" => "pt.json",
    "IT" => "it.xml",
    "MX" => "mx.json",
    "CO" => "co.json",
    "BR" => "br.json"
  }

  @doc "Has the country's provider answer every call with its recorded answer."
  def provider_answers(country) do
    file = Map.fetch!(@answers, country)
    body = File.read!(Path.join("test/fixtures/banking", file))
    type = if String.ends_with?(file, ".xml"), do: "application/xml", else: "application/json"

    Req.Test.stub(Fides.Banking.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  @doc "Starts a submitted application, as the orchestrator does, without evidence."
  def start(application) do
    Factory.insert(fn ->
      Origination.transition_application!(application, :validating, application.lock_version,
        tenant: application.country_code,
        actor: @system
      )
    end)
  end

  @doc "Runs `agent` on the application at its current version, as its job would."
  def agent(application, agent) do
    Oban.Testing.perform_job(
      AgentJob,
      %{
        agent: agent,
        application_id: application.id,
        country_code: application.country_code,
        lock_version: application.lock_version
      },
      repo: Fides.Platform.Repo
    )
  end

  @doc "The application as it is now."
  def current(application) do
    Origination.get_application!(application.id,
      tenant: application.country_code,
      authorize?: false
    )
  end

  @doc "Runs the agents in order until Risk decides, and returns the application as it stands."
  def decided(application) do
    for agent <- ~w(intake banking risk), reduce: start(application) do
      application ->
        :ok = agent(application, agent)
        current(application)
    end
  end
end
