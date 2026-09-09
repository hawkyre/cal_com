defmodule CalCom.Error do
  @moduledoc """
  The one failure shape every Cal.com call returns.

  Callers branch on `reason` without reading a provider body: an HTTP 401 and
  a documented body-level refusal both arrive as a closed reason. The raw
  provider payload rides in `payload` so nothing is lost to the taxonomy —
  credential-shaped keys are stripped before it is stored.

  The struct is an exception only so `raise`-free code can still hand it to
  supervisors and loggers with a readable message — this package never raises
  it for control flow.
  """

  @typedoc """
  Why the call failed.

  `:invalid_body` means the response did not match its generated contract and
  `payload` names the field. `:invalid_cursor` means pagination metadata
  contradicted itself, repeated a page, or repeated a cursor.
  """
  @type reason ::
          {:rate_limited, kind :: atom(), resume_at :: DateTime.t() | nil}
          | :unauthorized
          | :forbidden
          | :not_found
          | :invalid_body
          | :invalid_cursor
          | :validation
          | :provider_error
          | {:http, pos_integer()}

  @typedoc "The typed error carried by every failed Cal.com call."
  @type t :: %__MODULE__{
          reason: reason(),
          payload: term()
        }

  defexception [:reason, :payload]

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{reason: reason}) do
    "cal_com request failed: #{describe(reason)}"
  end

  @spec describe(reason()) :: String.t()
  defp describe({:rate_limited, kind, nil}), do: "rate limited (#{kind})"

  defp describe({:rate_limited, kind, %DateTime{} = resume_at}) do
    "rate limited (#{kind}), resume at #{DateTime.to_iso8601(resume_at)}"
  end

  defp describe(:unauthorized), do: "unauthorized"
  defp describe(:forbidden), do: "forbidden"
  defp describe(:not_found), do: "not found"
  defp describe(:invalid_body), do: "unparseable response body (see payload)"
  defp describe(:invalid_cursor), do: "invalid or repeated pagination cursor"
  defp describe(:validation), do: "provider rejected the input"
  defp describe(:provider_error), do: "provider rejected the operation (see payload)"
  defp describe({:http, status}), do: "unexpected http status #{status}"
end
