defmodule FidesWeb.ApiError do
  @moduledoc "Answers a request with one error in the API's JSON:API format."

  import Plug.Conn

  @spec send(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def send(conn, status, code, detail) do
    error = %{
      status: Integer.to_string(status),
      code: code,
      title: Plug.Conn.Status.reason_phrase(status),
      detail: detail
    }

    conn
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(status, Jason.encode!(%{errors: [error]}))
    |> halt()
  end
end
