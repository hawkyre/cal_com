defmodule CalCom.Schema do
  @moduledoc "Compile concrete embedded schemas from fixed Cal.com field declarations."
  alias CalCom.{Codec, Json, SourceContract}

  @doc "Define a concrete provider object with typed fields and a strict constructor."
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    {opts, source} = SourceContract.schema(opts, __CALLER__)
    fields = Keyword.fetch!(opts, :fields)

    additional =
      Keyword.get(
        opts,
        :additional,
        quote(do: %CalCom.Rule{kind: :json, nullable: true})
      )

    additional_type =
      Keyword.get(opts, :additional_type, quote(do: Json.t()))

    declarations =
      Enum.map(fields, fn {:{}, _meta, [name, _wire, _rule, type, _required]} ->
        quote do
          field(unquote(name), CalCom.Value) :: unquote(type) | nil
        end
      end)

    contracts =
      Enum.map(fields, fn {:{}, _meta, [name, wire, rule, _type, required]} ->
        quote do
          %CalCom.Field{
            name: unquote(name),
            wire: unquote(wire),
            rule: unquote(rule),
            required: unquote(required)
          }
        end
      end)

    quote do
      unquote_splicing(if source, do: [quote(do: @external_resource(unquote(source)))], else: [])
      use TypedEctoSchema
      @primary_key false
      @derive {Inspect, only: []}
      typed_embedded_schema do
        unquote_splicing(declarations)
        field(:provided, :any, virtual: true, default: MapSet.new()) :: MapSet.t(atom())

        field(:unknown_fields, CalCom.Value) :: [
          {String.t(), unquote(additional_type)}
        ]

        field :raw, :map, default: %{}
      end

      @doc "The complete fixed field contract."
      @spec fields() :: [CalCom.Field.t()]
      def fields, do: unquote(contracts)

      @doc "The rule for dynamic object keys."
      @spec additional_rule() :: CalCom.Rule.t() | false
      def additional_rule, do: unquote(additional)

      @doc "Parse untrusted provider fields into this concrete type."
      @spec parse(term()) :: {:ok, t()} | {:error, CalCom.Error.t()}
      def parse(raw), do: Codec.object(__MODULE__, raw)

      @doc "Serialize only fields present at construction."
      @spec encode(t()) :: map()
      def encode(%__MODULE__{} = value), do: Codec.object_wire(value)

      @doc "Identify this generated provider schema."
      @spec cal_schema?() :: true
      def cal_schema?, do: true
    end
  end
end
