defmodule FidesWeb.Api.ApplicationsApiTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use FidesWeb.ConnCase, async: false

  import FidesWeb.ApiHelpers

  alias Fides.Factory
  alias Fides.Origination.CreditApplication

  setup %{conn: conn} do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {_analyst, token} = staff_token("ES", :analyst, admin)
    {_foreign, foreign_token} = staff_token("MX", :analyst, admin)

    %{conn: conn, api: as(conn, token), foreign: as(conn, foreign_token), admin: admin}
  end

  defp applications, do: Ash.read!(CreditApplication, action: :visible, authorize?: false)

  defp create(ctx, overrides \\ %{}),
    do: ctx.api |> command("/api/applications", submission(overrides)) |> body()

  # The OpenAPI document as clients read it
  defp document(conn), do: conn |> get("/api/open_api") |> json_response(200)

  # The response body must match the schema the OpenAPI document gives it
  defp conforms?(response, method, path, status) do
    document = document(build_conn())

    schema =
      get_in(document, [
        "paths",
        path,
        method,
        "responses",
        Integer.to_string(status),
        "content",
        "application/vnd.api+json",
        "schema"
      ])

    assert schema, "#{method} #{path} documents no #{status} answer"
    assert valid?(body(response), schema, document), "#{method} #{path}: #{response.resp_body}"
    true
  end

  # The part of JSON Schema that AshJsonApi documents use
  defp valid?(value, %{"$ref" => "#/components/schemas/" <> name}, document),
    do: valid?(value, document["components"]["schemas"][name], document)

  defp valid?(value, %{"anyOf" => options}, document),
    do: Enum.any?(options, &valid?(value, &1, document))

  defp valid?(value, %{"enum" => enum} = schema, document),
    do: value in enum and valid?(value, Map.delete(schema, "enum"), document)

  defp valid?(value, %{"type" => "object"} = schema, document) when is_map(value) do
    properties = schema["properties"] || %{}

    Enum.all?(schema["required"] || [], &Map.has_key?(value, &1)) and
      (schema["additionalProperties"] != false or
         Enum.all?(Map.keys(value), &Map.has_key?(properties, &1))) and
      Enum.all?(properties, fn {key, property} ->
        not Map.has_key?(value, key) or valid?(value[key], property, document)
      end)
  end

  defp valid?(value, %{"type" => "array"} = schema, document) when is_list(value),
    do: Enum.all?(value, &valid?(&1, schema["items"] || %{}, document))

  defp valid?(value, %{"type" => type}, _document) do
    case type do
      "null" -> is_nil(value)
      "string" -> is_binary(value)
      "integer" -> is_integer(value)
      "number" -> is_number(value)
      "boolean" -> is_boolean(value)
      _object_or_array -> false
    end
  end

  defp valid?(_value, _unconstrained, _document), do: true

  test "every route of the API answers 401 without a staff token", ctx do
    id = Ash.UUIDv7.generate()
    plain = put_req_header(ctx.conn, "content-type", "application/vnd.api+json")

    requests = [
      get(plain, "/api/applications"),
      get(plain, "/api/applications/#{id}"),
      get(plain, "/api/applications/#{id}/transitions"),
      command(plain, "/api/applications", %{}),
      command(plain, "/api/applications/search", %{}),
      command(plain, "/api/applications/#{id}/transitions", %{}),
      command(plain, "/api/applications/#{id}/revisions", %{}),
      command(plain, "/api/applications/#{id}/reapply", %{})
    ]

    for response <- requests do
      assert %{"errors" => [%{"status" => "401"}]} = body(response)
    end
  end

  describe "creating" do
    test "takes an Idempotency-Key, and repeating the request repeats the answer", ctx do
      data = submission()

      without_key = post(ctx.api, "/api/applications", Jason.encode!(%{data: data}))

      assert %{"errors" => [%{"code" => "missing_idempotency_key"}]} =
               json_response(without_key, 422)

      assert applications() == []

      first = command(ctx.api, "/api/applications", data, "retry-1")
      again = command(ctx.api, "/api/applications", data, "retry-1")

      assert first.status == 201
      assert {again.status, body(again)} == {201, body(first)}
      assert [_one] = applications()

      other = command(ctx.api, "/api/applications", %{data | amount_minor: 5}, "retry-1")
      assert %{"errors" => [%{"code" => "idempotency_key_reused"}]} = json_response(other, 422)
      assert [_one] = applications()
    end

    test "refuses invalid data with an error for each field, and creates nothing", ctx do
      cases = [
        {%{amount_minor: 0}, "amount_minor"},
        {%{monthly_income_minor: -1}, "monthly_income_minor"},
        {%{currency: "MXN"}, "currency"},
        {%{holder: Map.delete(Factory.holder(), :email)}, "holder"},
        {%{holder: %{Factory.holder() | document: "12345678A"}}, nil}
      ]

      for {overrides, field} <- cases do
        response = command(ctx.api, "/api/applications", submission(overrides))
        assert %{"errors" => errors} = json_response(response, 422)

        # Each detail reads whole, its values put in
        refute Enum.any?(errors, &(&1["detail"] =~ "%{")), inspect(errors)

        if field do
          assert Enum.any?(
                   errors,
                   &String.contains?(get_in(&1, ["source", "pointer"]) || "", field)
                 ),
                 "#{inspect(overrides)}: #{inspect(errors)}"
        end
      end

      assert applications() == []
    end

    test "in Mexico, the holder's data must match the CURP", ctx do
      {_mexican, token} = staff_token("MX", :analyst, ctx.admin)
      api = as(ctx.conn, token)

      mexican = %{
        country_code: "MX",
        amount_minor: 10_000_000,
        monthly_income_minor: 3_000_000,
        currency: "MXN",
        consent_text_version: "2026-10",
        holder: mexican_holder()
      }

      without_birth_date = %{mexican | holder: Map.delete(mexican_holder(), :birth_date)}

      assert %{"errors" => _errors} =
               json_response(command(api, "/api/applications", without_birth_date), 422)

      assert %{"state" => "submitted", "country_code" => "MX"} =
               json_response(command(api, "/api/applications", mexican), 201)
    end

    test "the application never carries the holder's personal data", ctx do
      holder = Factory.holder()
      created = create(ctx, holder: holder)
      response = get(ctx.api, "/api/applications/#{created["id"]}")

      for text <- [response.resp_body, Jason.encode!(created)], value <- Map.values(holder) do
        refute text =~ value
      end
    end
  end

  describe "reading" do
    test "lists by country, state, dates and amounts", ctx do
      small = create(ctx, amount_minor: 100_000)
      large = create(ctx, amount_minor: 9_000_000)

      ids = fn query ->
        ctx.api
        |> get("/api/applications?" <> query)
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])
      end

      assert ids.("filter[country_code]=ES") == [large["id"], small["id"]]
      assert ids.("filter[country_code]=MX") == []

      assert ids.("filter[state]=submitted&filter[amount_minor][greater_than]=1000000") == [
               large["id"]
             ]

      assert ids.(
               "filter[submitted_at][greater_than]=#{URI.encode_www_form(large["submitted_at"])}"
             ) == []
    end

    test "pages with keyset without repeating or skipping, even when applications arrive", ctx do
      [first, second, third] = for _application <- 1..3, do: create(ctx)

      page = ctx.api |> get("/api/applications?page[limit]=2") |> json_response(200)
      assert Enum.map(page["data"], & &1["id"]) == [third["id"], second["id"]]

      # A newer application lands on the first page, never in the next one
      _newer = create(ctx)

      next = ctx.api |> get(page["links"]["next"]) |> json_response(200)
      assert Enum.map(next["data"], & &1["id"]) == [first["id"]]
    end

    test "searches by document in the body, never in the URL", ctx do
      holder = Factory.holder()
      found = create(ctx, holder: holder)
      _other = create(ctx)

      search = %{country_code: "ES", document: holder.document, limit: 10}
      response = command(ctx.api, "/api/applications/search", search)

      assert %{"data" => [%{"id" => id}], "next" => nil} = json_response(response, 201)
      assert id == found["id"]
      refute response.request_path =~ holder.document

      assert %{"data" => []} =
               ctx.api
               |> command("/api/applications/search", %{search | document: Factory.dni(1)})
               |> json_response(201)
    end

    test "the search filters and pages a holder's applications", ctx do
      holder = Factory.holder()

      cancel = fn application ->
        ctx.api
        |> command("/api/applications/#{application["id"]}/transitions", %{
          to: "cancelled",
          reason: "retried",
          expected_version: application["lock_version"]
        })
        |> json_response(201)
      end

      first = ctx |> create(holder: holder, amount_minor: 100_000) |> cancel.()
      second = ctx |> create(holder: holder, amount_minor: 200_000) |> cancel.()
      third = create(ctx, holder: holder, amount_minor: 300_000)

      search = %{country_code: "ES", document: holder.document, limit: 2}
      page = ctx.api |> command("/api/applications/search", search) |> json_response(201)
      assert Enum.map(page["data"], & &1["id"]) == [third["id"], second["id"]]

      next =
        ctx.api
        |> command("/api/applications/search", Map.put(search, :after, page["next"]))
        |> json_response(201)

      assert %{"data" => [%{"id" => id}], "next" => nil} = next
      assert id == first["id"]

      narrowed =
        Map.merge(search, %{
          state: "cancelled",
          min_amount_minor: 150_000,
          max_amount_minor: 250_000,
          submitted_from: first["submitted_at"],
          submitted_until: third["submitted_at"]
        })

      assert %{"data" => [%{"id" => only}]} =
               ctx.api |> command("/api/applications/search", narrowed) |> json_response(201)

      assert only == second["id"]
    end

    test "an application outside the actor's countries does not exist for them", ctx do
      created = create(ctx)

      assert %{"errors" => [%{"status" => "404"}]} =
               ctx.foreign |> get("/api/applications/#{created["id"]}") |> json_response(404)

      assert %{"data" => []} = ctx.foreign |> get("/api/applications") |> json_response(200)
    end
  end

  test "answers match the OpenAPI document", ctx do
    created = command(ctx.api, "/api/applications", submission())
    id = body(created)["id"]

    assert conforms?(created, "post", "/api/applications", 201)

    assert conforms?(
             get(ctx.api, "/api/applications/#{id}"),
             "get",
             "/api/applications/{id}",
             200
           )

    assert conforms?(get(ctx.api, "/api/applications"), "get", "/api/applications", 200)

    assert conforms?(
             get(ctx.api, "/api/applications/#{id}/transitions"),
             "get",
             "/api/applications/{id}/transitions",
             200
           )

    assert %{"openapi" => "3." <> _, "paths" => paths} =
             ctx.conn |> get("/api/open_api") |> json_response(200)

    assert Map.has_key?(paths, "/api/applications/{id}/transitions")
  end
end
