defmodule Sweep.Judge do
  @moduledoc """
  Turns one live call into one verdict.

  A 2xx that parses is `verified`; a non-2xx that classified into a documented
  reason is `refused` (the error path working); a 2xx that would not parse is
  `shape_mismatch`, with every offending field path named by walking the
  generated types over the raw body; a 429 is `throttled`, which the sweep that
  owns it re-runs. Mutations are reported as `write` so the read pass can skip
  them without pretending they were judged.
  """

  alias CalCom.{Codec, Credentials, Error, Operation, Response}
  alias Sweep.{Client, Inputs}

  @doc "The verdict for one operation."
  @spec judge(Operation.t(), Credentials.t(), map()) :: {String.t(), map()}
  def judge(%{method: method} = operation, _credentials, _discovered) when method != :get do
    {operation.id, %{status: "write", reason: "mutation: the read pass skips it"}}
  end

  def judge(operation, credentials, discovered) do
    case Inputs.params(operation, discovered) do
      {:ok, params} -> call(operation, credentials, params)
      {:invented, params, missing} -> probe(operation, credentials, params, missing)
    end
  end

  @doc "Call an operation and judge the result."
  @spec call(Operation.t(), Credentials.t(), map()) :: {String.t(), map()}
  def call(operation, credentials, params) do
    case Client.exchange(operation, credentials, params) do
      {:ok, %Response{status: 429} = package} ->
        {operation.id, %{status: "throttled", http: 429, reason: Client.throttle_note(package)}}

      {:ok, package} ->
        parse(operation, package)

      {:error, %Error{} = error} ->
        {operation.id, %{status: "input", reason: Client.describe(error)}}

      {:error, reason} ->
        {operation.id, %{status: "transport", reason: inspect(reason)}}
    end
  end

  # An operation the account has no id for is still worth one classified call:
  # it proves the request builds and the failure is named. The verdict stays
  # `unreachable`, because an invented id proves nothing about the success path.
  @spec probe(Operation.t(), Credentials.t(), map(), [String.t()]) :: {String.t(), map()}
  def probe(operation, credentials, params, missing) do
    {_id, verdict} = call(operation, credentials, params)

    {operation.id,
     verdict
     |> Map.drop([:capture, :fields])
     |> Map.put(:status, "unreachable")
     |> Map.put(:reason, "no #{Enum.join(missing, ", ")} on this account")
     |> Map.put(:probe, Map.take(verdict, [:status, :http, :reason]))}
  end

  @spec parse(Operation.t(), Response.t()) :: {String.t(), map()}
  defp parse(operation, package) do
    case operation.module.parse_response(package) do
      {:ok, typed} ->
        {operation.id, %{status: "verified", http: package.status, capture: {typed, package}}}

      {:error, %Error{reason: reason}} when package.status not in 200..299 ->
        {operation.id, %{status: "refused", http: package.status, reason: inspect(reason)}}

      {:error, %Error{} = error} ->
        {operation.id,
         %{
           status: "shape_mismatch",
           http: package.status,
           reason: Client.describe(error),
           fields: shape_report(operation, package),
           capture: {false, package}
         }}
    end
  end

  # A 2xx that would not parse is a contract bug. Walk the generated types over
  # the raw body and name every field that refused its value, so one live call
  # yields the whole fix list instead of the first failure.
  @spec shape_report(Operation.t(), Response.t()) :: [{String.t(), String.t()}]
  def shape_report(operation, package) do
    case Enum.find(operation.outputs, &(&1.status == package.status)) do
      nil ->
        []

      output ->
        rule = %CalCom.Rule{kind: {:object, output.module}}

        # The parser hands the body to the wrapper as its `value` field.
        case fails(rule, %{"value" => decode(package.body)}, []) do
          :ok -> []
          {:error, list} -> list
        end
    end
  end

  @spec decode(binary()) :: term()
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _invalid} -> body
    end
  end

  @spec fails(CalCom.Rule.t(), term(), [String.t()]) :: :ok | {:error, list()}
  defp fails(rule, value, path) do
    case Codec.value(rule, value) do
      {:ok, _parsed} -> :ok
      :error -> {:error, why(rule, value, path)}
    end
  end

  @spec why(CalCom.Rule.t(), term(), [String.t()]) :: list()
  defp why(%CalCom.Rule{kind: {:object, module}}, value, path) when is_map(value) do
    {absent, known} =
      Enum.split_with(module.fields(), &(&1.required and not Map.has_key?(value, &1.wire)))

    Enum.map(
      absent,
      &entry(path ++ [&1.wire], "required by the contract, absent from the response")
    ) ++
      Enum.flat_map(known, fn field ->
        with {:ok, raw} <- Map.fetch(value, field.wire),
             {:error, list} <- fails(field.rule, raw, path ++ [field.wire]) do
          list
        else
          _absent_or_ok -> []
        end
      end)
  end

  defp why(%CalCom.Rule{kind: {:object, module}}, value, path),
    do: [entry(path, "contract wants #{inspect(module)}, response has #{kind_of(value)}")]

  defp why(%CalCom.Rule{kind: {:array, item}}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} ->
      case fails(item, row, path ++ ["[#{index}]"]) do
        :ok -> []
        {:error, list} -> list
      end
    end)
  end

  defp why(%CalCom.Rule{kind: {:array, _item}}, value, path),
    do: [entry(path, "contract wants an array, response has #{kind_of(value)}")]

  defp why(%CalCom.Rule{kind: {group, rules}}, value, path) when group in [:one_of, :any_of] do
    attempts = for {rule, index} <- Enum.with_index(rules), do: {index, fails(rule, value, path)}

    case Enum.find(attempts, &match?({_index, :ok}, &1)) do
      {_index, :ok} ->
        []

      nil ->
        {closest, {:error, list}} =
          Enum.min_by(attempts, fn {_index, {:error, found}} -> length(found) end)

        [entry(path, "no variant accepted it; closest is variant #{closest}") | list]
    end
  end

  defp why(rule, value, path) do
    [entry(path, "refused #{inspect(value, limit: 3)}; contract is #{inspect(rule.kind)}")]
  end

  @spec kind_of(term()) :: String.t()
  defp kind_of(value) when is_map(value), do: "an object"
  defp kind_of(value) when is_list(value), do: "an array"
  defp kind_of(value) when is_binary(value), do: "a string"
  defp kind_of(value) when is_boolean(value), do: "a boolean"
  defp kind_of(nil), do: "null"
  defp kind_of(value), do: inspect(value, limit: 3)

  @spec entry([String.t()], String.t()) :: {String.t(), String.t()}
  defp entry(path, why), do: {Enum.join(path, "."), why}
end
