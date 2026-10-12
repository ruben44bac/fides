defmodule Mix.Tasks.Fides.Gen.Inventory do
  @shortdoc "Generates the data inventory from the data classification"

  @moduledoc """
  Writes `#{Fides.Platform.DataInventory.path()}` from the classification declared on
  every resource.

      mix fides.gen.inventory           # writes the file
      mix fides.gen.inventory --check   # fails if the file is out of date (CI)
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  alias Fides.Platform.DataInventory

  @requirements ["compile", "app.config"]

  @impl true
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: [check: :boolean])
    content = DataInventory.render()
    path = DataInventory.path()

    if opts[:check] do
      if File.read(path) != {:ok, content} do
        Mix.raise("#{path} is out of date. Run `mix fides.gen.inventory`.")
      end
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      Mix.shell().info("Wrote #{path}")
    end
  end
end
