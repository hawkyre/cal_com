defmodule CalCom.SourceCoverageTest do
  use ExUnit.Case, async: true

  alias CalCom.Registry
  alias CalCom.WebhookPayloads

  @source Path.expand("../../source", __DIR__)

  test "every pinned named object exposes each source property with its required flag" do
    schemas = named_schemas()
    index = read("source_index.json")
    assert map_size(index) == Enum.count(schemas, fn {_name, value} -> object?(value) end)

    for {name, schema} <- schemas, object?(schema) do
      module = String.to_existing_atom("Elixir." <> Map.fetch!(index, name))
      fields = module.fields()
      expected = schema |> Map.get("properties", %{}) |> Map.keys() |> Enum.sort()
      assert Enum.sort(Enum.map(fields, & &1.wire)) == expected, name
      required = MapSet.new(Map.get(schema, "required", []))

      for field <- fields do
        assert field.required == MapSet.member?(required, field.wire), name <> "." <> field.wire
      end
    end
  end

  test "every selected source operation retains its exact method, route, version and response statuses" do
    original = read("openapi.json")

    operations =
      Map.new(read("inventory.json")["operations"], fn id ->
        [method, route] = String.split(id, " ", parts: 2)
        {id, get_in(original, ["paths", route, String.downcase(method)])}
      end)

    assert map_size(operations) == length(Registry.all())

    for {id, source} <- operations do
      operation = Registry.find(id)
      [method, route] = String.split(id, " ", parts: 2)
      assert String.upcase(Atom.to_string(operation.method)) == method
      assert operation.path == route
      version = Enum.find(Map.get(source, "parameters", []), &(&1["name"] == "cal-api-version"))

      expected_version =
        get_in(version || %{}, ["schema", "default"]) ||
          get_in(version || %{}, ["schema", "example"])

      assert operation.version == expected_version
      if version && version["required"], do: assert(is_binary(operation.version))
      statuses = source["responses"] |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "2"))
      assert Enum.sort(Enum.map(operation.outputs, &to_string(&1.status))) == Enum.sort(statuses)
    end
  end

  test "generated schemas declare their contract file as a compiler dependency" do
    index = read("source_index.json")
    {_name, module_name} = Enum.at(index, 0)
    module = String.to_existing_atom("Elixir." <> module_name)

    attributes = module.__info__(:attributes)
    resources = attributes |> Keyword.get_values(:external_resource) |> List.flatten()

    assert Enum.any?(resources, &String.contains?(&1, "schema_contracts_"))
  end

  test "webhook dispatch covers the full provider trigger enum and every documented root field" do
    schemas = read("openapi.json")["components"]["schemas"]

    triggers =
      get_in(schemas, ["CreateWebhookInputDto", "properties", "triggers", "items", "enum"])

    assert Enum.sort(WebhookPayloads.events()) == Enum.sort(triggers)

    for {event, shape} <- read("webhook_shapes.json") do
      assert {:ok, typed} = WebhookPayloads.parse(%{"triggerEvent" => event})
      expected = shape["properties"] |> Map.keys() |> Enum.sort()
      assert Enum.sort(Enum.map(typed.__struct__.fields(), & &1.wire)) == expected
    end
  end

  @spec object?(map()) :: boolean()
  defp object?(schema), do: schema["type"] == "object" or Map.has_key?(schema, "properties")

  @spec named_schemas() :: map()
  defp named_schemas do
    original = read("openapi.json")["components"]["schemas"]
    Map.take(original, Map.keys(read("source_index.json")))
  end

  @spec read(String.t()) :: map()
  defp read(file), do: @source |> Path.join(file) |> File.read!() |> Jason.decode!()
end
