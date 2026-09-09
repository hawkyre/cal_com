defmodule CalCom.Webhook do
  @moduledoc "Authenticate and parse versioned Cal.com webhook deliveries."
  alias CalCom.{Codec, WebhookPayloads}
  alias CalCom.Error
  @enforce_keys [:event, :version, :value]
  @derive {Inspect, only: [:event, :version]}
  defstruct [:event, :version, :value]

  @typedoc "An authenticated event with every documented payload field."
  @type t :: %__MODULE__{event: String.t(), version: String.t(), value: WebhookPayloads.t()}

  @doc "Verify HMAC-SHA256 over the exact raw body bytes."
  @spec verify(binary(), [{String.t(), String.t()}], keyword()) :: boolean()
  def verify(body, headers, opts) when is_binary(body) and is_list(headers) and is_list(opts) do
    with secret when is_binary(secret) and byte_size(secret) > 0 <- Keyword.get(opts, :secret),
         {:ok, supplied} <- supplied_signature(headers) do
      equal_signature?(:crypto.mac(:hmac, :sha256, secret, body), supplied)
    else
      _invalid -> false
    end
  end

  def verify(_body, _headers, _opts), do: false

  @spec supplied_signature([{String.t(), String.t()}]) :: {:ok, binary()} | :error
  defp supplied_signature(headers) do
    with true <- single_header?(headers, "x-cal-signature-256"),
         signature when is_binary(signature) <- header(headers, "x-cal-signature-256") do
      Base.decode16(signature, case: :mixed)
    else
      _invalid -> :error
    end
  end

  @doc "Verify the signature before parsing the provider version and typed payload."
  @spec parse(binary(), [{String.t(), String.t()}], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def parse(body, headers, opts) do
    with true <- verify(body, headers, opts),
         {:ok, version} <- version(headers),
         {:ok, raw} <- Jason.decode(body),
         {:ok, value} <- WebhookPayloads.parse(raw) do
      {:ok, %__MODULE__{event: raw["triggerEvent"], version: version, value: value}}
    else
      false -> {:error, %Error{reason: :unauthorized}}
      {:error, %Error{}} = error -> error
      _invalid -> Codec.invalid("webhook version or JSON")
    end
  end

  @spec version([{String.t(), String.t()}]) :: {:ok, String.t()} | {:error, Error.t()}
  defp version(headers) do
    value = header(headers, "x-cal-webhook-version")

    if single_header?(headers, "x-cal-webhook-version") and value in ["2021-10-20", "2026-07-27"],
      do: {:ok, value},
      else: Codec.invalid("webhook version")
  end

  # A delivery carries each header exactly once; a repeated one is a forgery
  # attempt that would otherwise let the first value win silently.
  @spec single_header?([{String.t(), String.t()}], String.t()) :: boolean()
  defp single_header?(headers, expected) do
    Enum.count(headers, fn
      {name, _value} when is_binary(name) -> String.downcase(name) == expected
      _invalid -> false
    end) == 1
  end

  @spec header([{String.t(), String.t()}], String.t()) :: String.t() | nil
  defp header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: value
      _invalid -> nil
    end)
  end

  @spec equal_signature?(binary(), binary()) :: boolean()
  defp equal_signature?(expected, supplied), do: :crypto.hash_equals(expected, supplied)
end
