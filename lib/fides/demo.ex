defmodule Fides.Demo do
  @moduledoc """
  The three scripted scenarios, run against a running Fides through its API as an
  integration would, and followed state by state while the agents work: an application
  approved on its own, one approved after an analyst's review, and one the policy
  rejects, through Mexico's asynchronous provider. The back office shows them move as
  they happen.

  Every run applies for new, fictitious holders, so nothing depends on what earlier runs
  left behind.
  """

  use Boundary, deps: [Fides.Accounts, Fides.Identity], exports: []

  alias Fides.Accounts.Demo, as: Staff
  alias Fides.Identity.Documents.Samples

  @final ~w(approved rejected cancelled)

  @scenarios [
    %{
      name: "Approved on its own",
      country: "ES",
      handle: "analyst_es",
      amount_minor: 1_000_000,
      monthly_income_minor: 250_000,
      currency: "EUR",
      review: nil,
      expected: "approved"
    },
    %{
      name: "Approved after review",
      country: "ES",
      handle: "analyst_es",
      amount_minor: 2_500_000,
      monthly_income_minor: 250_000,
      currency: "EUR",
      review: {"in_review", "approved", "The income covers the instalments"},
      expected: "approved"
    },
    %{
      name: "Rejected by the policy",
      country: "MX",
      handle: "analyst_mx",
      amount_minor: 50_000_000,
      monthly_income_minor: 5_000_000,
      currency: "MXN",
      review: nil,
      expected: "rejected"
    }
  ]

  @typedoc """
  How the run is driven: the app's `url`, where each line goes (`log`), what runs before
  each poll (`tick`, for tests that work the queues themselves), the `interval` between
  polls and the `timeout` of each scenario, in milliseconds, and a `seed` that makes
  the holders of this run.
  """
  @type option ::
          {:url, String.t()}
          | {:log, (String.t() -> any())}
          | {:tick, (-> any())}
          | {:interval, non_neg_integer()}
          | {:timeout, pos_integer()}
          | {:seed, integer()}

  @doc "Runs the three scenarios in order; an error says what stopped the run or which scenarios failed."
  @spec run([option()]) :: :ok | {:error, String.t()}
  def run(opts \\ []) do
    client = %{
      url: Keyword.get(opts, :url, "http://localhost:4000"),
      log: Keyword.get(opts, :log, &IO.puts/1),
      tick: Keyword.get(opts, :tick, fn -> :ok end),
      interval: Keyword.get(opts, :interval, 300),
      timeout: Keyword.get(opts, :timeout, 90_000),
      seed: Keyword.get(opts, :seed, System.os_time(:millisecond))
    }

    client.log.("Fides demo against #{client.url}. Watch them move at #{client.url}/backoffice.")
    started = System.monotonic_time(:millisecond)

    with {:ok, tokens} <- sign_in_all(client) do
      results =
        @scenarios
        |> Enum.with_index(1)
        |> Enum.map(fn {scenario, index} -> play(scenario, index, tokens, client) end)

      case Enum.reject(results, & &1.ok?) do
        [] ->
          client.log.("")
          client.log.("All three scenarios ended as expected in #{seconds(started)}.")
          :ok

        failed ->
          {:error,
           "#{length(failed)} of 3 scenarios did not end as expected: " <>
             Enum.map_join(failed, "; ", &"#{&1.name} #{&1.reason}")}
      end
    end
  end

  # A code works once, so each demo user signs in once for the whole run
  defp sign_in_all(client) do
    @scenarios
    |> Enum.map(& &1.handle)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn handle, {:ok, tokens} ->
      case sign_in(handle, client) do
        {:ok, token} -> {:cont, {:ok, Map.put(tokens, handle, token)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp play(scenario, index, tokens, client) do
    started = System.monotonic_time(:millisecond)
    token = Map.fetch!(tokens, scenario.handle)

    client.log.("")

    client.log.(
      "#{index}/3  #{scenario.name} — #{country(scenario.country)}, " <>
        "#{money(scenario.amount_minor, scenario.currency)} at " <>
        "#{money(scenario.monthly_income_minor, scenario.currency)} a month"
    )

    with {:ok, application} <- submit(scenario, index, token, client),
         {:ok, state} <- follow(application, scenario, token, client, started) do
      if state == scenario.expected do
        client.log.("     ✓ #{label(state)} in #{seconds(started)}")
        %{name: scenario.name, ok?: true, reason: nil}
      else
        reason = "ended #{label(state)}, expected #{label(scenario.expected)}"
        client.log.("     ✗ #{reason}")
        %{name: scenario.name, ok?: false, reason: reason}
      end
    else
      {:error, reason} ->
        client.log.("     ✗ #{reason}")
        %{name: scenario.name, ok?: false, reason: reason}
    end
  end

  # Follows one application until a final state, polling as a person would refresh
  defp follow(application, scenario, token, client, started) do
    run = %{
      id: application["id"],
      scenario: scenario,
      token: token,
      client: client,
      started: started,
      deadline: System.monotonic_time(:millisecond) + client.timeout
    }

    client.log.("     → #{label(application["state"])}  #{seconds(started)}")
    poll(run, application["state"])
  end

  defp poll(run, seen) do
    run.client.tick.()

    case read(run.id, run.token, run.client) do
      {:ok, %{"state" => state, "lock_version" => version}} ->
        if state != seen, do: run.client.log.("     → #{label(state)}  #{seconds(run.started)}")
        next(run, state, version)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What follows the state just read: the end, the analyst's part, or another look
  defp next(run, state, version) do
    cond do
      state in @final ->
        {:ok, state}

      state == "provider_error" ->
        {:error, "the provider failed: are the mocks running, on :4010?"}

      System.monotonic_time(:millisecond) > run.deadline ->
        {:error, "still #{label(state)} after #{div(run.client.timeout, 1000)} s"}

      match?({^state, _to, _reason}, run.scenario.review) ->
        review(run, version)

      true ->
        Process.sleep(run.client.interval)
        poll(run, state)
    end
  end

  defp review(%{scenario: %{review: {_state, to, reason}}} = run, version) do
    run.client.log.("     the analyst decides: #{label(to)}, \"#{reason}\"")

    case transition(run.id, to, reason, version, run.token, run.client) do
      {:ok, moved} -> poll(%{run | scenario: %{run.scenario | review: nil}}, moved["state"])
      {:error, reason} -> {:error, reason}
    end
  end

  defp sign_in(handle, client) do
    staff = Staff.user(handle)
    body = %{email: staff.email, password: Staff.password(), totp_code: Staff.totp_code(handle)}

    case Req.post(request(client), url: "/api/auth/token", json: body) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 401}} ->
        {:error,
         "#{handle} could not sign in. A code works once: if they just signed in, " <>
           "run this again when the code changes."}

      {:ok, %{status: status}} ->
        {:error, "POST /api/auth/token answered #{status}"}

      {:error, exception} ->
        {:error,
         "Could not reach #{client.url}: #{Exception.message(exception)}. Is the app running?"}
    end
  end

  # Each scenario applies for a holder of its own
  defp submit(scenario, index, token, client) do
    data = %{
      country_code: scenario.country,
      amount_minor: scenario.amount_minor,
      monthly_income_minor: scenario.monthly_income_minor,
      currency: scenario.currency,
      channel: "api",
      consent_text_version: Fides.Identity.consent_text_version(),
      holder: holder(scenario.country, client.seed + index)
    }

    command(client, token, "/api/applications", data)
  end

  defp transition(id, to, reason, version, token, client) do
    command(client, token, "/api/applications/#{id}/transitions", %{
      to: to,
      reason: reason,
      expected_version: version
    })
  end

  defp read(id, token, client) do
    case Req.get(request(client, token), url: "/api/applications/#{id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, decode(body)["data"]["attributes"]}
      {:ok, %{status: status}} -> {:error, "GET /api/applications/#{id} answered #{status}"}
      {:error, exception} -> {:error, "could not reach the app: #{Exception.message(exception)}"}
    end
  end

  # Commands answer with the application itself, or with each error and its field
  defp command(client, token, path, data) do
    headers = [{"idempotency-key", Ecto.UUID.generate()}]

    case Req.post(request(client, token),
           url: path,
           headers: headers,
           body: Jason.encode!(%{data: data})
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, "POST #{path} answered #{status}: #{errors(body)}"}

      {:error, exception} ->
        {:error, "could not reach the app: #{Exception.message(exception)}"}
    end
  end

  defp request(client, token \\ nil) do
    headers =
      [{"accept", "application/vnd.api+json"}, {"content-type", "application/vnd.api+json"}] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    Req.new([base_url: client.url, headers: headers, retry: false] ++ req_options())
  end

  defp req_options,
    do: :fides |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

  defp decode(body) when is_binary(body), do: Jason.decode!(body)
  defp decode(body), do: body

  defp errors(body) do
    case decode(body) do
      %{"errors" => errors} when is_list(errors) ->
        Enum.map_join(errors, "; ", fn error ->
          pointer = get_in(error, ["source", "pointer"])
          String.trim("#{pointer} #{error["detail"] || error["title"]}")
        end)

      _other ->
        "an unexpected answer"
    end
  end

  # Fictitious holders, new in every run: the seed makes their documents
  defp holder("ES", seed) do
    %{
      document_type: "DNI",
      document: Samples.dni(seed),
      given_names: "Lucía",
      first_surname: "Demo",
      second_surname: "Ferrer",
      email: "lucia.demo+#{seed}@example.com"
    }
  end

  defp holder("MX", seed) do
    birth_date =
      Date.new!(1950 + rem(seed, 50), 1 + rem(div(seed, 50), 12), 1 + rem(div(seed, 600), 28))

    holder = %{
      document_type: "CURP",
      given_names: "Gloria",
      first_surname: "Demo",
      second_surname: "García",
      birth_date: birth_date,
      sex: :female,
      email: "gloria.demo+#{seed}@example.com"
    }

    Map.put(holder, :document, Samples.curp(holder))
  end

  defp label(state), do: String.replace(state, "_", " ")

  defp seconds(started),
    do: "#{Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)} s"

  defp country("ES"), do: "Spain"
  defp country("MX"), do: "Mexico"
  defp country(code), do: code

  defp money(minor, currency) do
    units =
      minor
      |> div(100)
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    cents = minor |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{units}.#{cents}"
  end
end
