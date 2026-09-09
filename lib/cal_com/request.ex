defmodule CalCom.Request do
  @moduledoc """
  A description of one HTTP request the caller makes on the package's behalf.

  The package never opens a socket — it returns this struct and the caller
  sends it with whatever client they already use. `private` carries the
  parsed call and its credentials so `CalCom.Pagination` can build the next
  page without re-parsing the caller's input; it is never sent on the wire.
  """

  @enforce_keys [:url]
  defstruct method: :get, url: nil, headers: [], body: nil, private: %{}

  @typedoc "An HTTP header pair as sent on the wire."
  @type header :: {String.t(), String.t()}

  @typedoc "A pure request description; `private` never leaves the process."
  @type t :: %__MODULE__{
          method: :get | :post | :put | :patch | :delete,
          url: String.t(),
          headers: [header()],
          body: iodata() | nil,
          private: map()
        }

  @doc """
  The request with `entries` merged into its private state.

  ## Examples

      iex> request = %CalCom.Request{url: "https://example.test"}
      iex> CalCom.Request.put_private(request, queue: ["a", "b"]).private
      %{queue: ["a", "b"]}
  """
  @spec put_private(t(), keyword() | map()) :: t()
  def put_private(%__MODULE__{} = request, entries) do
    %{request | private: Map.merge(request.private, Map.new(entries))}
  end
end
