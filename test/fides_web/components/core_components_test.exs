defmodule FidesWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import FidesWeb.CoreComponents

  defp html(rendered), do: rendered |> rendered_to_string() |> LazyHTML.from_fragment()
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  describe "flash/1" do
    test "shows the message of its kind with an optional title" do
      assigns = %{flash: %{"info" => "Saved", "error" => "Failed"}}

      doc =
        html(~H"""
        <.flash kind={:info} flash={@flash} title="Done" />
        <.flash kind={:error} flash={@flash} />
        """)

      assert text(doc, "#flash-info") =~ "Done"
      assert text(doc, "#flash-info") =~ "Saved"
      assert text(doc, "#flash-error") =~ "Failed"
    end

    test "renders nothing without a message" do
      assigns = %{}

      doc = html(~H|<.flash kind={:info} flash={%{}} />|)

      assert count(doc, "[role=alert]") == 0
    end
  end

  test "button/1 is a button, or a link when it navigates" do
    assigns = %{}

    doc =
      html(~H"""
      <.button id="save" variant="primary">Save</.button>
      <.button id="home" navigate="/">Home</.button>
      """)

    assert count(doc, "button#save.btn-primary") == 1
    assert count(doc, "a#home[href='/']") == 1
  end

  describe "input/1" do
    test "takes its name, value and errors from a form field" do
      form =
        to_form(%{"email" => "ana@example.com"}, as: :user, errors: [email: {"is invalid", []}])

      assigns = %{form: form}

      doc = html(~H|<.input field={@form[:email]} type="email" label="Email" />|)

      assert count(
               doc,
               "input#user_email[type=email][name='user[email]'][value='ana@example.com']"
             ) ==
               1

      assert text(doc, "label") =~ "Email"
      assert text(doc, "p") =~ "is invalid"
    end

    test "renders hidden, checkbox, select and textarea inputs" do
      assigns = %{options: [{"Mexico", "MX"}, {"Spain", "ES"}]}

      doc =
        html(~H"""
        <.input type="hidden" id="token" name="token" value="abc" />
        <.input type="checkbox" id="terms" name="terms" value="true" label="Accept" />
        <.input type="select" id="country" name="country" value="MX" prompt="Choose" options={@options} />
        <.input type="textarea" id="notes" name="notes" value="Hello" errors={["too short"]} />
        """)

      assert count(doc, "input#token[type=hidden][value=abc]") == 1
      assert count(doc, "input#terms[type=checkbox][checked]") == 1
      assert count(doc, "select#country option[value=MX][selected]") == 1
      assert count(doc, "select#country option[value='']") == 1
      assert text(doc, "textarea#notes") == "Hello"
      assert count(doc, "textarea#notes.textarea-error") == 1
    end

    test "a multiple select from a form field submits a list" do
      assigns = %{form: to_form(%{"countries" => ["MX"]}, as: :filter)}

      doc =
        html(
          ~H|<.input field={@form[:countries]} type="select" multiple options={["MX", "ES"]} />|
        )

      assert count(doc, "select[name='filter[countries][]'][multiple]") == 1
    end
  end

  test "header/1 renders the title, subtitle and actions" do
    assigns = %{}

    doc =
      html(~H"""
      <.header>
        Applications
        <:subtitle>All countries</:subtitle>
        <:actions><.button id="new">New</.button></:actions>
      </.header>
      """)

    assert text(doc, "h1") == "Applications"
    assert text(doc, "header p") == "All countries"
    assert count(doc, "header button#new") == 1
  end

  test "table/1 renders a row per item with its columns and actions" do
    assigns = %{rows: [%{id: 1, code: "MX"}, %{id: 2, code: "ES"}]}

    doc =
      html(~H"""
      <.table
        id="countries"
        rows={@rows}
        row_id={fn row -> "country-#{row.id}" end}
        row_click={fn row -> "show-#{row.id}" end}
      >
        <:col :let={country} label="Code">{country.code}</:col>
        <:action :let={country}><span class="action">Open {country.code}</span></:action>
      </.table>
      """)

    assert text(doc, "thead th") =~ "Code"
    assert count(doc, "tbody#countries tr") == 2
    assert text(doc, "#country-2 td") =~ "ES"
    assert text(doc, "#country-1 .action") == "Open MX"
  end

  test "list/1 renders each item with its title" do
    assigns = %{}

    doc =
      html(~H"""
      <.list>
        <:item title="Currency">MXN</:item>
        <:item title="Region">latam</:item>
      </.list>
      """)

    assert count(doc, "li") == 2
    assert text(doc, "li") =~ "Currency"
  end

  test "icon/1 renders a hero icon" do
    assigns = %{}

    doc = html(~H|<.icon name="hero-x-mark" class="size-3" />|)

    assert count(doc, "span.hero-x-mark.size-3") == 1
  end

  test "show/2 and hide/2 target the given selector" do
    assert [["show", %{to: "#modal"}]] = show("#modal").ops
    assert [["hide", %{to: "#modal"}]] = hide("#modal").ops
  end

  test "translate_error/1 interpolates and pluralizes" do
    assert translate_error({"should be at least %{count} character(s)", [count: 3]}) ==
             "should be at least 3 character(s)"

    assert translate_error({"is invalid", []}) == "is invalid"

    assert translate_errors([email: {"is invalid", []}, name: {"can't be blank", []}], :email) ==
             ["is invalid"]
  end
end
