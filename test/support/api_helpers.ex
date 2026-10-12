defmodule FidesWeb.ApiHelpers do
  @moduledoc "Requests to the staff API as a given staff user."

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Phoenix.ConnTest
  import Plug.Conn

  alias Fides.Accounts.Totp
  alias Fides.Factory

  @endpoint FidesWeb.Endpoint
  @json_api "application/vnd.api+json"

  @doc "A staff user with `role` in each of `countries`, granted by `admin`, and their token."
  def staff_token(countries, role, admin) do
    {user, secret} = Factory.staff_user()
    for country <- List.wrap(countries), do: Factory.scope(user, country, role, admin)
    {user, token(user, secret)}
  end

  @doc "A bearer token for a staff user and their TOTP secret."
  def token(user, secret) do
    {:ok, token, _claims} =
      Fides.Accounts.sign_in(to_string(user.email), Factory.staff_password(), Totp.code(secret))

    token
  end

  @doc "A connection that speaks JSON:API as the holder of `token`."
  def as(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", @json_api)
    |> put_req_header("content-type", @json_api)
  end

  @doc "Sends a command with its inputs in `data`, under an Idempotency-Key."
  def command(conn, path, data, key \\ Ecto.UUID.generate()) do
    conn
    |> put_req_header("idempotency-key", key)
    |> post(path, Jason.encode!(%{data: data}))
  end

  @doc "The decoded body of a response."
  def body(conn), do: Jason.decode!(conn.resp_body)

  @doc "A Spanish submission, as the API takes it."
  def submission(overrides \\ %{}),
    do: Map.put(Factory.submission(overrides), :country_code, "ES")

  @doc "A Mexican holder whose CURP matches their data."
  def mexican_holder do
    %{
      document_type: "CURP",
      document: "HEGG560427MVZRRL04",
      given_names: "Gloria",
      first_surname: "Hernández",
      second_surname: "García",
      birth_date: "1956-04-27",
      sex: "female",
      email: "gloria@example.com"
    }
  end
end
