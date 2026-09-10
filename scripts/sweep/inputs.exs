defmodule Sweep.Inputs do
  @moduledoc """
  Synthesizes a typed input for an operation from its own generated contract.

  Every value comes from the field's rule, so the sample cannot drift from the
  contract: an enum samples its first member, an array its minimum length, a
  bounded number its minimum, and a string the first candidate that the rule
  accepts. Path parameters use ids the account owns; when the account has none,
  the value is an id that cannot name a real row (0 or "none") and the caller is
  told which parameters those were.
  """

  alias CalCom.{Codec, Field, Rule}

  @doc "The input parts for an operation, plus the path parameters it had to invent."
  @spec params(CalCom.Operation.t(), map()) :: {:ok, map()} | {:invented, map(), [String.t()]}
  def params(operation, discovered) do
    fields = operation.input_module.fields()
    {path, missing} = path_values(fields, discovered)

    parts =
      %{
        "path" => path,
        "query" => required_of(fields, "query"),
        "headers" => required_of(fields, "headers"),
        "body" => required_of(fields, "body")
      }
      |> Enum.reject(fn {_part, value} -> value == %{} end)
      |> Map.new()

    if missing == [], do: {:ok, parts}, else: {:invented, parts, missing}
  end

  @doc "Every field an object module marks required, sampled."
  @spec required_fields(module()) :: map()
  def required_fields(module) do
    module.fields()
    |> Enum.filter(& &1.required)
    |> Map.new(fn field -> {field.wire, sample(field.rule)} end)
  end

  @doc "A value the rule accepts."
  @spec sample(Rule.t()) :: term()
  def sample(%Rule{kind: {:object, module}}), do: required_fields(module)
  def sample(%Rule{kind: {:enum, [{wire, _value} | _rest]}}), do: wire

  def sample(%Rule{kind: {:array, item}, min_items: min}),
    do: List.duplicate(sample(item), min || 0)

  def sample(%Rule{kind: kind, minimum: minimum, maximum: maximum})
      when kind in [:integer, :number],
      do: minimum || if(is_number(maximum) and maximum < 0, do: maximum, else: 0)

  def sample(%Rule{kind: :boolean}), do: false
  def sample(%Rule{kind: :date}), do: "2000-01-01"
  def sample(%Rule{kind: :datetime}), do: "2000-01-01T00:00:00Z"
  def sample(%Rule{kind: :json}), do: nil
  def sample(%Rule{kind: {:one_of, rules}} = rule), do: variant(rule, rules)
  def sample(%Rule{kind: {:any_of, rules}} = rule), do: variant(rule, rules)

  def sample(%Rule{kind: :string} = rule) do
    candidates = [
      String.duplicate("a", rule.min_length || 1),
      "https://example.invalid",
      "test@example.invalid",
      "2000-01-01",
      "00:00",
      "en",
      "UTC",
      "+10000000000",
      "00000000-0000-4000-8000-000000000000"
    ]

    Enum.find(candidates, &match?({:ok, _}, Codec.value(rule, &1))) ||
      raise "no sample value for #{inspect(rule.pattern)}"
  end

  @spec variant(Rule.t(), [Rule.t()]) :: term()
  defp variant(rule, rules) do
    case Enum.find_value(rules, fn choice ->
           value = sample(choice)
           if match?({:ok, _}, Codec.value(rule, value)), do: {:sample, value}
         end) do
      {:sample, value} -> value
      nil -> raise "no valid variant"
    end
  end

  @spec required_of([Field.t()], String.t()) :: map()
  defp required_of(fields, part) do
    case Enum.find(fields, &(&1.wire == part)) do
      nil -> %{}
      %{rule: %{kind: {:object, module}}} -> required_fields(module)
    end
  end

  @spec path_values([Field.t()], map()) :: {map(), [String.t()]}
  defp path_values(fields, discovered) do
    case Enum.find(fields, &(&1.wire == "path")) do
      nil ->
        {%{}, []}

      %{rule: %{kind: {:object, module}}} ->
        Enum.reduce(module.fields(), {%{}, []}, fn field, {acc, missing} ->
          case Map.get(discovered, field.wire, []) do
            [value | _rest] -> {Map.put(acc, field.wire, value), missing}
            [] -> {Map.put(acc, field.wire, absent_id(field.rule)), [field.wire | missing]}
          end
        end)
    end
  end

  # A probe id that cannot name a real row: 0 for numbers, "none" for strings.
  @spec absent_id(Rule.t()) :: term()
  defp absent_id(%Rule{kind: kind}) when kind in [:integer, :number], do: 0
  defp absent_id(%Rule{kind: {:enum, [{wire, _value} | _rest]}}), do: wire
  defp absent_id(_rule), do: "none"
end
