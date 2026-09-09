defmodule CalCom.Credentials do
  @moduledoc """
  Explicit Cal.com credentials with no environment access.

  The package reads no configuration, so the caller states what to send:
  an API key, an OAuth access token, or nothing for an unauthenticated
  operation. The token is opaque — this package never parses or refreshes it.
  """

  alias CalCom.Codec

  @derive {Inspect, only: [:kind]}
  defstruct token: nil, kind: :none

  @typedoc "Opaque credentials owned by the caller."
  @type t :: %__MODULE__{token: String.t() | nil, kind: :oauth | :api_key | :none}

  @doc "Parse credentials without changing the token."
  @spec parse(term()) :: {:ok, t()} | {:error, CalCom.Error.t()}
  def parse(%{"kind" => "none"}), do: {:ok, %__MODULE__{}}

  def parse(%{"token" => token, "kind" => kind}) when is_binary(token) and byte_size(token) > 0 do
    if String.contains?(token, ["\r", "\n"]) do
      Codec.invalid("credentials.token")
    else
      case kind do
        "oauth" -> {:ok, %__MODULE__{kind: :oauth, token: token}}
        "api_key" -> {:ok, %__MODULE__{kind: :api_key, token: token}}
        _unknown -> Codec.invalid("credentials.kind")
      end
    end
  end

  def parse(_raw), do: Codec.invalid("credentials")
end
