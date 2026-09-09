defmodule CalCom.Response do
  @moduledoc """
  One HTTP response as the caller's transport hands it back.

  `headers` keeps the wire shape the major clients produce — a map of
  lowercased names to value lists — and `body` is the raw undecoded binary:
  parsing belongs to this package, not the transport.
  """

  @enforce_keys [:status]
  defstruct status: nil, headers: %{}, body: ""

  @typedoc "Lowercased header name to its values, as received."
  @type headers :: %{optional(String.t()) => [String.t()]}

  @typedoc "A raw response; `body` is undecoded bytes."
  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: headers(),
          body: binary()
        }

  @doc """
  The first value of `name`, matched case-insensitively, or `nil`.

  ## Examples

      iex> response = %CalCom.Response{status: 200, headers: %{"x-rate" => ["10"]}}
      iex> CalCom.Response.header(response, "X-Rate")
      "10"
      iex> CalCom.Response.header(response, "absent")
      nil
  """
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) do
    case Map.get(headers, String.downcase(name), []) do
      [first | _rest] -> first
      [] -> nil
    end
  end

  @doc """
  The instant a `Retry-After` header points at, or `nil` when it is absent
  or unreadable.

  Only the whole-seconds form is read. The HTTP-date form is legal but the
  provider does not send it, and guessing at a date format would invent a
  resume time rather than read one.

  ## Examples

      iex> response = %CalCom.Response{status: 429, headers: %{"retry-after" => ["30"]}}
      iex> DateTime.diff(CalCom.Response.retry_after(response), DateTime.utc_now()) > 28
      true
      iex> CalCom.Response.retry_after(%CalCom.Response{status: 429})
      nil
  """
  @spec retry_after(t()) :: DateTime.t() | nil
  def retry_after(%__MODULE__{} = response) do
    with value when is_binary(value) <- header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      DateTime.add(DateTime.utc_now(), seconds, :second)
    else
      _absent -> nil
    end
  end
end
