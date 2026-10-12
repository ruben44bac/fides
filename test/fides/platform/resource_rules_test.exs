defmodule Fides.Platform.ResourceRulesTest do
  use ExUnit.Case, async: true

  alias Fides.Platform.Classification

  describe "classification" do
    test "a resource with an unclassified attribute does not compile" do
      assert_raise Spark.Error.DslError, ~r/attributes without classification: \[:notes\]/, fn ->
        defmodule Elixir.Fides.Countries.UnclassifiedProbe do
          use Fides.Platform.Resource,
            domain: Fides.Countries.TestDomain,
            data_layer: Ash.DataLayer.Ets

          attributes do
            uuid_v7_primary_key :id
            attribute :notes, :string
          end

          classification do
            attribute :id, :pseudonymous
          end
        end
      end
    end

    test "classifying an attribute that does not exist does not compile" do
      assert_raise Spark.Error.DslError,
                   ~r/classification for unknown attributes: \[:ghost\]/,
                   fn ->
                     defmodule Elixir.Fides.Countries.GhostProbe do
                       use Fides.Platform.Resource,
                         domain: Fides.Countries.TestDomain,
                         data_layer: Ash.DataLayer.Ets

                       attributes do
                         uuid_v7_primary_key :id
                       end

                       classification do
                         attribute :id, :pseudonymous
                         attribute :ghost, :public
                       end
                     end
                   end
    end

    test "pii and internal attributes become sensitive" do
      probe = Fides.Countries.SensitiveProbe
      assert Ash.Resource.Info.attribute(probe, :email).sensitive?
      refute Ash.Resource.Info.attribute(probe, :amount_minor).sensitive?
      assert Classification.Info.class_of(probe, :email) == :pii
      assert Classification.Info.attributes_of_class(probe, :pii) == [:email]
    end

    test "every resource of the app uses the platform extensions" do
      resources = Spark.sparks(:fides, Ash.Resource)
      assert resources != []

      for resource <- resources do
        assert Fides.Platform.Resource.extensions() -- Spark.extensions(resource) == [],
               "#{inspect(resource)} must `use Fides.Platform.Resource`"
      end
    end
  end

  describe "context isolation" do
    test "a relationship to another context does not compile" do
      assert_raise Spark.Error.DslError, ~r/outside context Fides.Countries/, fn ->
        defmodule Elixir.Fides.Countries.CrossProbe do
          use Fides.Platform.Resource,
            domain: Fides.Countries.TestDomain,
            data_layer: Ash.DataLayer.Ets

          attributes do
            uuid_v7_primary_key :id
          end

          relationships do
            belongs_to :application, Fides.Origination.CreditApplication
          end

          classification do
            attribute :id, :pseudonymous
            attribute :application_id, :pseudonymous
          end
        end
      end
    end

    test "a resource must live inside a context" do
      assert_raise Spark.Error.DslError, ~r/is not under a known Fides.<Context> namespace/, fn ->
        defmodule Elixir.Fides.Platform.OutsideProbe do
          use Fides.Platform.Resource,
            domain: Fides.Countries.TestDomain,
            data_layer: Ash.DataLayer.Ets

          attributes do
            uuid_v7_primary_key :id
          end

          classification do
            attribute :id, :pseudonymous
          end
        end
      end
    end

    test "a resource cannot use another context's domain" do
      assert_raise Spark.Error.DslError, ~r/must use a domain of Fides.Risk/, fn ->
        defmodule Elixir.Fides.Risk.MisplacedProbe do
          use Fides.Platform.Resource,
            domain: Fides.Countries.TestDomain,
            data_layer: Ash.DataLayer.Ets

          attributes do
            uuid_v7_primary_key :id
          end

          classification do
            attribute :id, :pseudonymous
          end
        end
      end
    end
  end
end
