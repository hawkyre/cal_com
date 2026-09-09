defmodule CalCom.OperationModule do
  @moduledoc "Compile typed entry points for one fixed Cal.com operation."
  alias CalCom.{RequestBuilder, ResponseParser, SourceContract}

  @doc "Define request and response functions with concrete input and result types."
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    {opts, source} = SourceContract.operation(opts, __CALLER__)
    input = Keyword.fetch!(opts, :input)
    result = Keyword.fetch!(opts, :result)
    contract = Keyword.fetch!(opts, :contract)

    quote do
      unquote_splicing(if source, do: [quote(do: @external_resource(unquote(source)))], else: [])
      @typedoc "The concrete request input."
      @type input :: unquote(input).t()
      @typedoc "The documented response variants."
      @type result :: unquote(result)

      @doc "Return the fixed provider contract."
      @spec definition() :: CalCom.Operation.t()
      def definition, do: unquote(contract)

      @doc "Parse inputs at the boundary."
      @spec parse_input(term()) :: {:ok, input()} | {:error, CalCom.Error.t()}
      def parse_input(raw), do: unquote(input).parse(raw)

      @doc "Build the request from a concrete parsed input."
      @spec request(input(), CalCom.Credentials.t()) ::
              {:ok, CalCom.Request.t()} | {:error, CalCom.Error.t()}
      def request(%unquote(input){} = input, credentials) do
        call = %CalCom.Call{operation: definition(), input: input}
        RequestBuilder.request(call, credentials)
      end

      @doc "Parse the response into its declared result variant."
      @spec parse_response(CalCom.Response.t()) ::
              {:ok, result()} | {:error, CalCom.Error.t()}
      def parse_response(response),
        do: ResponseParser.parse(definition(), response)
    end
  end
end
