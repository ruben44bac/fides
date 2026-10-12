defmodule Mix.Tasks.Fides.Gen.Lifecycles do
  @shortdoc "Generates the diagram of each country's life cycle"

  @moduledoc """
  Writes `#{Fides.Origination.Lifecycle.Diagram.path()}` from each country's life
  cycle: a Mermaid diagram, and what runs on entering each state.

      mix fides.gen.lifecycles           # writes the file
      mix fides.gen.lifecycles --check   # fails if the file is out of date (CI)
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  alias Fides.Origination.Lifecycle.Diagram

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: [check: :boolean])
    content = Diagram.render()
    path = Diagram.path()

    if opts[:check] do
      if File.read(path) != {:ok, content} do
        Mix.raise("#{path} is out of date. Run `mix fides.gen.lifecycles`.")
      end
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      Mix.shell().info("Wrote #{path}")
    end
  end
end
