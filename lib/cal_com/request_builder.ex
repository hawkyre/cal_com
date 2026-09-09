defmodule CalCom.RequestBuilder do
  @moduledoc "Serialize concrete Cal.com inputs into pure request descriptions."
  alias CalCom.{Call, Codec, Context, Credentials}
  alias CalCom.{Error, Request}

  @doc "Build one supported request with explicit credentials."
  @spec request(Call.t(), Credentials.t()) :: {:ok, Request.t()} | {:error, Error.t()}
  def request(%Call{operation: operation} = call, %Credentials{} = credentials) do
    with :ok <- safe_credentials(credentials),
         {:ok, params} <- parameters(call),
         {:ok, path} <- path(operation.path, Map.get(params, "path", %{})),
         {:ok, extra_headers} <- headers(Map.get(params, "headers", %{})) do
      {:ok, render(call, credentials, params, path, extra_headers)}
    end
  end

  @spec parameters(Call.t()) :: {:ok, map()} | {:error, Error.t()}
  defp parameters(%Call{operation: operation, input: input}) do
    with true <- is_struct(input, operation.input_module),
         {:ok, parsed} <- operation.input_module.parse(Codec.object_wire(input)) do
      {:ok, Codec.object_wire(parsed)}
    else
      false -> Codec.invalid("input module")
      {:error, _error} = error -> error
    end
  end

  @spec render(Call.t(), Credentials.t(), map(), String.t(), [{String.t(), String.t()}]) ::
          Request.t()
  defp render(%Call{operation: operation} = call, credentials, params, path, extra_headers) do
    query = query_pairs(Map.get(params, "query", %{}), operation.path)
    body = encode_body(Map.get(params, "body"), operation.media_type)

    %Request{
      method: operation.method,
      url: url(path, URI.encode_query(query)),
      body: body,
      headers: request_headers(operation, credentials, body) ++ extra_headers,
      private: %{cal_com: %Context{call: call, credentials: credentials}}
    }
  end

  @spec request_headers(CalCom.Operation.t(), Credentials.t(), binary() | nil) ::
          [{String.t(), String.t()}]
  defp request_headers(operation, credentials, body),
    do:
      auth_headers(credentials) ++
        version_header(operation.version) ++ content_header(body, operation.media_type)

  @doc "Encode Cal.com query arrays according to the documented operation contracts."
  @spec query_pairs(map(), String.t()) :: [{String.t(), String.t()}]
  def query_pairs(query, path) do
    Enum.flat_map(query, fn {key, value} -> query_value(key, value, path) end)
  end

  @spec query_value(String.t(), term(), String.t()) :: [{String.t(), String.t()}]
  defp query_value("calendarsToLoad" = key, values, "/v2/calendars/busy-times")
       when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      Enum.map(entry, fn {field, value} -> {"#{key}[#{index}][#{field}]", scalar(value)} end)
    end)
  end

  defp query_value(key, values, path) when is_list(values) do
    if key in ["status", "teamIds", "assignedOptionIds"] or
         (key == "emails" and path == "/v2/teams/{teamId}/memberships") do
      [{key, Enum.map_join(values, ",", &scalar/1)}]
    else
      Enum.map(values, &{key, scalar(&1)})
    end
  end

  defp query_value(key, value, _path), do: [{key, scalar(value)}]

  @spec scalar(term()) :: String.t()
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp scalar(nil), do: ""

  @spec path(String.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  defp path(template, values) do
    result =
      Enum.reduce_while(values, {:ok, template}, fn {key, value}, {:ok, result} ->
        case scalar(value) do
          "" ->
            {:halt, Codec.invalid("path." <> key)}

          segment ->
            encoded = URI.encode(segment, &URI.char_unreserved?/1)
            {:cont, {:ok, String.replace(result, "{" <> key <> "}", encoded)}}
        end
      end)

    complete_path(result)
  end

  @spec complete_path({:ok, String.t()} | {:error, Error.t()}) ::
          {:ok, String.t()} | {:error, Error.t()}
  defp complete_path({:ok, path}) do
    if String.contains?(path, ["{", "}"]),
      do: Codec.invalid("missing path parameter"),
      else: {:ok, path}
  end

  defp complete_path({:error, _error} = error), do: error

  @spec headers(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  defp headers(values) do
    Enum.reduce_while(values, {:ok, []}, fn {name, value}, {:ok, result} ->
      encoded = scalar(value)

      if String.contains?(encoded, ["\r", "\n"]) do
        {:halt, Codec.invalid("header")}
      else
        {:cont, {:ok, [{String.downcase(name), encoded} | result]}}
      end
    end)
  end

  @spec safe_credentials(Credentials.t()) :: :ok | {:error, Error.t()}
  defp safe_credentials(%Credentials{kind: :none}), do: :ok

  defp safe_credentials(%Credentials{token: token})
       when is_binary(token) and byte_size(token) > 0 do
    if String.contains?(token, ["\r", "\n"]), do: Codec.invalid("credentials.token"), else: :ok
  end

  defp safe_credentials(_credentials), do: Codec.invalid("credentials")

  @spec auth_headers(Credentials.t()) :: [{String.t(), String.t()}]
  defp auth_headers(%Credentials{kind: :none}), do: []
  defp auth_headers(%Credentials{token: token}), do: [{"authorization", "Bearer " <> token}]

  @spec version_header(String.t() | nil) :: [{String.t(), String.t()}]
  defp version_header(nil), do: []
  defp version_header(version), do: [{"cal-api-version", version}]

  @spec content_header(iodata() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  defp content_header(nil, _media_type), do: []
  defp content_header(_body, media_type), do: [{"content-type", media_type}]

  @spec encode_body(term(), String.t() | nil) :: binary() | nil
  defp encode_body(nil, _media_type), do: nil
  defp encode_body(body, "application/x-www-form-urlencoded"), do: URI.encode_query(body)
  defp encode_body(body, _media_type), do: Jason.encode!(body)

  @spec url(String.t(), String.t()) :: String.t()
  defp url(path, ""), do: "https://api.cal.com" <> path
  defp url(path, query), do: "https://api.cal.com" <> path <> "?" <> query
end
