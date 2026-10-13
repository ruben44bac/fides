defmodule FidesWeb.HealthController do
  @moduledoc """
  Answers the health checks of whatever runs the image: ok while the database
  answers, unavailable otherwise.
  """

  use FidesWeb, :controller

  alias Fides.Platform.Repo

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _result} ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
