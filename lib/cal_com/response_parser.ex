defmodule CalCom.ResponseParser do
  @moduledoc "Parse Cal.com response envelopes into their generated concrete types."
  alias CalCom.{Codec, Operation, Output, PageMeta}
  alias CalCom.{Error, Response}

  @doc "Parse the exact success-status variant."
  @spec parse(Operation.t(), Response.t()) :: {:ok, struct()} | {:error, Error.t()}
  def parse(%Operation{outputs: outputs}, %Response{} = response) do
    with :ok <- classify(response),
         %Output{} = output <- Enum.find(outputs, &(&1.status == response.status)),
         {:ok, decoded} <- decode(response.body, output.empty?) do
      output.module.parse(%{"value" => decoded})
    else
      nil -> http_error(response)
      {:error, _error} = error -> error
    end
  end

  @doc "Classify documented HTTP and body-level failure signals."
  @spec classify(Response.t()) :: :ok | {:error, Error.t()}
  def classify(%Response{status: status} = response) when status in 200..299 do
    case Jason.decode(response.body) do
      {:ok, %{"status" => "error"}} -> http_error(response)
      {:ok, %{"error" => _error}} -> http_error(response)
      _other -> :ok
    end
  end

  def classify(%Response{status: 401} = response), do: error(:unauthorized, response)
  def classify(%Response{status: 403} = response), do: error(:forbidden, response)
  def classify(%Response{status: 404} = response), do: error(:not_found, response)

  def classify(%Response{status: 429} = response),
    do: error({:rate_limited, :provider, Response.retry_after(response)}, response)

  def classify(%Response{} = response), do: http_error(response)

  @doc "Extract typed continuation metadata from a parsed result."
  @spec meta(Response.t(), struct()) :: PageMeta.t()
  def meta(response, %{value: value}) do
    body = Codec.wire(value)
    pagination = member(body, "pagination")
    data = member(body, "data")

    %PageMeta{
      status: response.status,
      cursor: member(pagination, "nextCursor"),
      has_more: member(pagination, "hasMore"),
      has_next_page: member(pagination, "hasNextPage"),
      returned_items: member(pagination, "returnedItems"),
      remaining_items: member(pagination, "remainingItems"),
      total_items: member(pagination, "totalItems"),
      count: count(data),
      total: member(data, "total"),
      retry_after: Response.header(response, "retry-after")
    }
  end

  @spec decode(binary(), boolean()) :: {:ok, term()} | {:error, Error.t()}
  defp decode("", true), do: {:ok, nil}

  defp decode(body, _empty?) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _error} -> Codec.invalid("response JSON")
    end
  end

  @spec member(term(), String.t()) :: term()
  defp member(value, key) when is_map(value), do: Map.get(value, key)
  defp member(_value, _key), do: nil

  @spec count(term()) :: non_neg_integer()
  defp count(values) when is_list(values), do: length(values)
  defp count(%{"auditLogs" => values}) when is_list(values), do: length(values)
  defp count(%{"data" => values}) when is_list(values), do: length(values)
  defp count(nil), do: 0
  defp count(_value), do: 1

  @spec http_error(Response.t()) :: {:error, Error.t()}
  defp http_error(response), do: error({:http, response.status}, response)

  @spec error(Error.reason(), Response.t()) :: {:error, Error.t()}
  defp error(reason, response) do
    payload =
      case Jason.decode(response.body) do
        {:ok, decoded} -> Codec.redact(decoded)
        {:error, _error} -> response.body
      end

    {:error, %Error{reason: reason, payload: payload}}
  end
end
