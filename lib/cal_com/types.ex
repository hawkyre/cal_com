defmodule CalCom.Rule do
  @moduledoc "A fixed wire-value rule compiled from the Cal.com API contract."
  defstruct kind: :json,
            nullable: false,
            minimum: nil,
            maximum: nil,
            min_length: nil,
            max_length: nil,
            min_items: nil,
            max_items: nil,
            pattern: nil,
            unique_items: false

  @typedoc "A closed description of a supported wire value."
  @type kind ::
          :json
          | :string
          | :integer
          | :number
          | :boolean
          | :date
          | :datetime
          | {:object, module()}
          | {:array, t()}
          | {:enum, [{term(), atom() | number() | boolean()}]}
          | {:one_of, [t()]}
          | {:any_of, [t()]}
  @typedoc "A value rule, including the provider's constraints."
  @type t :: %__MODULE__{
          kind: kind(),
          nullable: boolean(),
          minimum: number() | nil,
          maximum: number() | nil,
          min_length: non_neg_integer() | nil,
          max_length: non_neg_integer() | nil,
          min_items: non_neg_integer() | nil,
          max_items: non_neg_integer() | nil,
          pattern: String.t() | nil,
          unique_items: boolean()
        }
end

defmodule CalCom.Field do
  @moduledoc "One documented field and its fixed internal name."
  alias CalCom.Rule
  @enforce_keys [:name, :wire, :rule]
  defstruct [:name, :wire, :rule, required: false]
  @typedoc "A compiled field contract."
  @type t :: %__MODULE__{name: atom(), wire: String.t(), rule: Rule.t(), required: boolean()}
end

defmodule CalCom.Json do
  @moduledoc "A recursively typed value for provider-defined dynamic JSON."
  @enforce_keys [:kind, :value]
  defstruct [:kind, :value]
  @typedoc "A dynamic JSON value without untyped object maps."
  @type t :: %__MODULE__{
          kind: :scalar | :array | :object,
          value: String.t() | number() | boolean() | nil | [t()] | [{String.t(), t()}]
        }

  @doc "Parse a value at the wire boundary."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: {:ok, %__MODULE__{kind: :scalar, value: value}}

  def parse(value) when is_list(value), do: collect(value, :array)

  def parse(value) when is_map(value) and not is_struct(value),
    do: collect(Map.to_list(value), :object)

  def parse(_value), do: :error

  @doc "Serialize a typed dynamic value at the wire boundary."
  @spec encode(t()) :: term()
  def encode(%__MODULE__{kind: :scalar, value: value}), do: value
  def encode(%__MODULE__{kind: :array, value: values}), do: Enum.map(values, &encode/1)

  def encode(%__MODULE__{kind: :object, value: entries}),
    do: Map.new(entries, fn {key, value} -> {key, encode(value)} end)

  @spec collect(list(), :array | :object) :: {:ok, t()} | :error
  defp collect(values, kind) do
    result =
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case parse_entry(value, kind) do
          {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
          :error -> {:halt, :error}
        end
      end)

    case result do
      {:ok, parsed} -> {:ok, %__MODULE__{kind: kind, value: Enum.reverse(parsed)}}
      :error -> :error
    end
  end

  @spec parse_entry(term(), :array | :object) :: {:ok, term()} | :error
  defp parse_entry({key, value}, :object) when is_binary(key) do
    with {:ok, parsed} <- parse(value), do: {:ok, {key, parsed}}
  end

  defp parse_entry(value, :array), do: parse(value)
  defp parse_entry(_value, _kind), do: :error
end

defmodule CalCom.Alternatives do
  @moduledoc "All typed interpretations of an anyOf value."
  @enforce_keys [:values]
  defstruct [:values]
  @typedoc "Matching typed alternatives, retained without field loss."
  @type t :: %__MODULE__{values: [struct() | String.t() | number() | boolean() | nil]}
end

defmodule CalCom.Value do
  @moduledoc "An in-memory Ecto type for already parsed Cal.com values."
  use Ecto.Type
  @typedoc "A value whose concrete type is declared by its generated field."
  @type t :: struct() | String.t() | number() | boolean() | nil | [t()]
  @impl true
  @spec type() :: :map
  def type, do: :map
  @impl true
  @spec cast(term()) :: {:ok, t()} | :error
  def cast(value)
      when is_struct(value) or is_binary(value) or is_number(value) or is_boolean(value) or
             is_nil(value) or is_list(value),
      do: {:ok, value}

  def cast(_value), do: :error
  @impl true
  @spec load(term()) :: :error
  def load(_value), do: :error
  @impl true
  @spec dump(term()) :: :error
  def dump(_value), do: :error
end
