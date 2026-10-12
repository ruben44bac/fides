defmodule Fides.Origination.ApplicationCommands.Run do
  @moduledoc """
  Runs a command of `Fides.Origination.ApplicationCommands`: finds the application
  among those the actor may see, then calls the application's own action in its
  country, with the same actor.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Fides.Origination
  alias Fides.Origination.CreditApplication
  alias Fides.Origination.Moves

  @impl true
  def run(input, opts, context), do: command(opts[:command], input.arguments, context.actor)

  defp command(:submit, arguments, actor) do
    {country, submission} = Map.pop(arguments, :country_code)
    Origination.submit_application(submission, tenant: country, actor: actor)
  end

  defp command(:transitions, %{id: id}, actor) do
    with {:ok, application} <- visible(id, actor) do
      {:ok,
       %{
         state: application.state,
         lock_version: application.lock_version,
         transitions: Moves.available(application, actor)
       }}
    end
  end

  defp command(:transition, arguments, actor) do
    with {:ok, application} <- visible(arguments.id, actor) do
      Origination.transition_application(
        application,
        arguments.to,
        arguments.expected_version,
        %{reason: arguments[:reason]},
        tenant: application.country_code,
        actor: actor
      )
    end
  end

  defp command(:revise, arguments, actor) do
    with {:ok, application} <- visible(arguments.id, actor) do
      Origination.answer_information_request(
        application,
        Map.take(arguments, [:amount_minor, :monthly_income_minor, :expected_version]),
        tenant: application.country_code,
        actor: actor
      )
    end
  end

  defp command(:reapply, arguments, actor) do
    with {:ok, previous} <- visible(arguments.id, actor) do
      arguments
      |> Map.delete(:id)
      |> Map.put(:previous_application_id, previous.id)
      |> Origination.reapply(tenant: previous.country_code, actor: actor)
    end
  end

  defp command(:search, arguments, actor) do
    case Fides.Identity.holder_of_document(arguments.country_code, arguments.document) do
      {:ok, nil} -> {:ok, %{data: [], next: nil}}
      {:ok, holder} -> page(arguments, holder.id, actor)
      {:error, error} -> {:error, error}
    end
  end

  defp visible(id, actor), do: Ash.get(CreditApplication, id, action: :visible, actor: actor)

  defp page(arguments, person_id, actor) do
    country = arguments.country_code

    CreditApplication
    |> Ash.Query.for_read(:visible, %{}, actor: actor)
    |> Ash.Query.filter(country_code == ^country and person_id == ^person_id)
    |> narrow(arguments)
    |> Ash.read(
      page: Enum.reject([limit: arguments.limit, after: arguments[:after]], &is_nil(elem(&1, 1)))
    )
    |> case do
      {:ok, %{results: results, more?: more?}} ->
        next = if more?, do: Ash.Resource.get_metadata(List.last(results), :keyset)
        {:ok, %{data: results, next: next}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp narrow(query, arguments) do
    Enum.reduce(arguments, query, fn
      {:state, state}, query when not is_nil(state) ->
        Ash.Query.filter(query, state == ^state)

      {:submitted_from, from}, query when not is_nil(from) ->
        Ash.Query.filter(query, submitted_at >= ^from)

      {:submitted_until, until}, query when not is_nil(until) ->
        Ash.Query.filter(query, submitted_at <= ^until)

      {:min_amount_minor, min}, query when not is_nil(min) ->
        Ash.Query.filter(query, amount_minor >= ^min)

      {:max_amount_minor, max}, query when not is_nil(max) ->
        Ash.Query.filter(query, amount_minor <= ^max)

      _other, query ->
        query
    end)
  end
end
