defmodule CalCom.Codec do
  @moduledoc "The single strict boundary for Cal.com wire values."
  alias CalCom.{Alternatives, Field, Json, Rule}
  alias CalCom.Error

  @doc "Parse every documented field into the requested concrete schema."
  @spec object(module(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def object(module, raw) when is_map(raw) and not is_struct(raw) do
    result =
      Enum.reduce_while(module.fields(), {:ok, []}, fn %Field{} = field, {:ok, values} ->
        case field_value(field, raw) do
          {:ok, value} -> {:cont, {:ok, [{field.name, value} | values]}}
          :absent -> {:cont, {:ok, values}}
          :error -> {:halt, invalid(field.wire)}
        end
      end)

    finish_object(result, module, raw)
  end

  def object(_module, _raw), do: invalid("object")

  @doc "Parse a value using a fixed compiled rule."
  @spec value(Rule.t(), term()) :: {:ok, term()} | :error
  def value(%Rule{nullable: true}, nil), do: {:ok, nil}
  def value(%Rule{kind: :json}, raw), do: Json.parse(raw)

  def value(%Rule{} = rule, raw) do
    if constraints?(rule, raw), do: kind(rule.kind, raw), else: :error
  end

  @doc "Serialize a parsed object without adding absent PATCH fields."
  @spec object_wire(struct()) :: map()
  def object_wire(%{__struct__: module, provided: provided} = value) do
    module.fields()
    |> Enum.filter(&MapSet.member?(provided, &1.name))
    |> Map.new(fn field -> {field.wire, wire(Map.fetch!(value, field.name))} end)
    |> Map.merge(Map.new(value.unknown_fields, fn {key, extra} -> {key, wire(extra)} end))
  end

  @doc "Serialize a typed value at the request boundary."
  @spec wire(term()) :: term()
  def wire(%Json{} = value), do: Json.encode(value)
  def wire(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def wire(%Date{} = value), do: Date.to_iso8601(value)

  def wire(%Alternatives{values: [head | tail]}) do
    Enum.reduce(tail, wire(head), fn value, acc ->
      case {acc, wire(value)} do
        {%{} = left, %{} = right} -> Map.merge(left, right)
        {same, same} -> same
      end
    end)
  end

  def wire(%{__struct__: _module, provided: _provided} = value), do: object_wire(value)
  def wire(values) when is_list(values), do: Enum.map(values, &wire/1)
  def wire(value) when is_boolean(value) or is_nil(value), do: value
  def wire(value) when is_atom(value), do: Atom.to_string(value)
  def wire(value) when is_binary(value) or is_number(value), do: value

  @doc "Remove credentials before preserving a provider payload."
  @spec redact(term()) :: term()
  def redact(raw) when is_map(raw) do
    raw
    |> Enum.reject(fn {key, _value} -> secret_key?(key) end)
    |> Map.new(fn {key, value} -> {key, redact(value)} end)
  end

  def redact(raw) when is_list(raw), do: Enum.map(raw, &redact/1)
  def redact(raw), do: raw

  @doc "Return a payload-shape error without copying request secrets."
  @spec invalid(String.t()) :: {:error, Error.t()}
  def invalid(field),
    do: {:error, %Error{reason: :invalid_body, payload: field}}

  @spec field_value(Field.t(), map()) :: {:ok, term()} | :absent | :error
  defp field_value(%Field{wire: key, required: required, rule: rule}, raw) do
    case Map.fetch(raw, key) do
      {:ok, raw_value} -> value(rule, raw_value)
      :error when required -> :error
      :error -> :absent
    end
  end

  @spec finish_object({:ok, keyword()} | {:error, Error.t()}, module(), map()) ::
          {:ok, struct()} | {:error, Error.t()}
  defp finish_object({:ok, values}, module, raw) do
    provided = values |> Keyword.keys() |> MapSet.new()
    known = Enum.map(module.fields(), & &1.wire)

    with {:ok, additional} <- extra_values(Map.drop(raw, known), module.additional_rule()) do
      {:ok,
       struct(
         module,
         values ++ [provided: provided, unknown_fields: additional, raw: redact(raw)]
       )}
    end
  end

  defp finish_object({:error, _error} = error, _module, _raw), do: error

  @spec extra_values(map(), Rule.t() | false) ::
          {:ok, [{String.t(), term()}]} | {:error, Error.t()}
  defp extra_values(extra, false) when map_size(extra) == 0, do: {:ok, []}
  defp extra_values(_extra, false), do: invalid("additionalProperties")

  defp extra_values(extra, rule) do
    Enum.reduce_while(extra, {:ok, []}, fn {key, raw}, {:ok, acc} ->
      case value(rule, raw) do
        {:ok, parsed} -> {:cont, {:ok, [{key, parsed} | acc]}}
        :error -> {:halt, invalid("additionalProperties")}
      end
    end)
  end

  @spec kind(Rule.kind(), term()) :: {:ok, term()} | :error
  defp kind(:string, raw) when is_binary(raw), do: {:ok, raw}
  defp kind(:integer, raw) when is_integer(raw), do: {:ok, raw}
  defp kind(:number, raw) when is_number(raw), do: {:ok, raw}
  defp kind(:boolean, raw) when is_boolean(raw), do: {:ok, raw}

  defp kind(:date, raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp kind(:datetime, raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp kind({:object, module}, raw) do
    case module.parse(raw) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp kind({:array, rule}, raw) when is_list(raw) do
    result =
      Enum.reduce_while(raw, {:ok, []}, fn item, {:ok, acc} ->
        case value(rule, item) do
          {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
          :error -> {:halt, :error}
        end
      end)

    reverse_values(result)
  end

  defp kind({:enum, pairs}, raw) do
    case List.keyfind(pairs, raw, 0) do
      {_wire, parsed} -> {:ok, parsed}
      nil -> :error
    end
  end

  defp kind({:one_of, rules}, raw) do
    case matching(rules, raw) do
      [parsed] -> {:ok, parsed}
      [] -> :error
      values -> overlapping_objects(values)
    end
  end

  defp kind({:any_of, rules}, raw) do
    case matching(rules, raw) do
      [] -> :error
      values -> {:ok, %Alternatives{values: values}}
    end
  end

  defp kind(_kind, _raw), do: :error

  @spec overlapping_objects([term()]) :: {:ok, struct()} | :error
  defp overlapping_objects(values) do
    # Cal.com booking schemas overlap: recurring and standard inputs have identical
    # required fields. Select only a variant that exposes every known field.
    if Enum.all?(values, &match?(%{provided: %MapSet{}}, &1)) do
      known = Enum.reduce(values, MapSet.new(), &MapSet.union(&1.provided, &2))

      case Enum.find(values, &MapSet.equal?(&1.provided, known)) do
        nil -> :error
        selected -> {:ok, selected}
      end
    else
      :error
    end
  end

  @spec matching([Rule.t()], term()) :: [term()]
  defp matching(rules, raw) do
    Enum.flat_map(rules, fn rule ->
      case value(rule, raw) do
        {:ok, parsed} -> [parsed]
        :error -> []
      end
    end)
  end

  @spec reverse_values({:ok, list()} | :error) :: {:ok, list()} | :error
  defp reverse_values({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_values(:error), do: :error

  @spec constraints?(Rule.t(), term()) :: boolean()
  defp constraints?(rule, raw) do
    numeric_bounds?(rule, raw) and length_bounds?(rule, raw) and pattern?(rule.pattern, raw) and
      unique?(rule, raw)
  end

  @spec unique?(Rule.t(), term()) :: boolean()
  defp unique?(%Rule{unique_items: true}, raw) when is_list(raw),
    do: length(Enum.uniq(raw)) == length(raw)

  defp unique?(_rule, _raw), do: true

  @spec numeric_bounds?(Rule.t(), term()) :: boolean()
  defp numeric_bounds?(%Rule{minimum: min, maximum: max}, raw) when is_number(raw),
    do: (is_nil(min) or raw >= min) and (is_nil(max) or raw <= max)

  defp numeric_bounds?(_rule, _raw), do: true

  @spec length_bounds?(Rule.t(), term()) :: boolean()
  defp length_bounds?(%Rule{min_length: min, max_length: max}, raw) when is_binary(raw),
    do: bounds?(String.length(raw), min, max)

  defp length_bounds?(%Rule{min_items: min, max_items: max}, raw) when is_list(raw),
    do: bounds?(length(raw), min, max)

  defp length_bounds?(_rule, _raw), do: true

  @spec bounds?(non_neg_integer(), non_neg_integer() | nil, non_neg_integer() | nil) :: boolean()
  defp bounds?(size, min, max), do: (is_nil(min) or size >= min) and (is_nil(max) or size <= max)

  @spec pattern?(String.t() | nil, term()) :: boolean()
  defp pattern?(nil, _raw), do: true

  defp pattern?(pattern, raw) when is_binary(raw) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> Regex.match?(regex, raw)
      {:error, _reason} -> false
    end
  end

  defp pattern?(_pattern, _raw), do: false

  @spec secret_key?(term()) :: boolean()
  defp secret_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(["_", "-"], "")

    normalized in [
      "secret",
      "clientsecret",
      "accesstoken",
      "refreshtoken",
      "authorization",
      "apikey",
      "password",
      "token",
      "webhooksecret",
      "xcalsecretkey",
      "codeverifier",
      "code",
      "onetimepassword"
    ]
  end

  defp secret_key?(_key), do: false
end
