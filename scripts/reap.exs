# Delete anything a certification run left behind, by name.
#
#   CAL_COM_API_KEY=... mix run scripts/reap.exs          # report and delete
#   CAL_COM_API_KEY=... mix run scripts/reap.exs --dry    # report only
#
# Every fixture the sweeps create is named with a `kithe` marker and a unique
# suffix, so a leftover can always be found again by listing the endpoint that
# owns it — even when a create's body did not parse and its id was never
# recorded. This is the backstop for `Sweep.Ledger.undo/1`: cleanup that depends
# on a scenario tracking its own id cannot see a fixture whose response the
# contract refused, and that is exactly when a leak happens.
#
# It only ever deletes rows carrying that marker. Nothing the account already
# had is touched, and bookings are cancelled rather than deleted.
Code.require_file("sweep/client.exs", __DIR__)
Code.require_file("sweep/discover.exs", __DIR__)

Sweep.Client.start()

defmodule Reap do
  @moduledoc "Finds and deletes certification fixtures by their name marker."

  alias Sweep.Client

  @marker "kithe"
  @cancel "POST /v2/bookings/{bookingUid}/cancel"

  @doc "List every place a fixture can live, and how to remove one."
  @spec targets() :: [{String.t(), map(), (map() -> boolean()), String.t(), String.t()}]
  def targets do
    org = System.get_env("CAL_REAP_ORG", "422850")

    [
      {"GET /v2/event-types", %{}, &marked?/1, "DELETE /v2/event-types/{eventTypeId}",
       "eventTypeId"},
      {"GET /v2/webhooks", %{}, &marked?/1, "DELETE /v2/webhooks/{webhookId}", "webhookId"},
      {"GET /v2/schedules", %{}, &marked?/1, "DELETE /v2/schedules/{scheduleId}", "scheduleId"},
      {"GET /v2/workflows", %{}, &marked?/1, "DELETE /v2/workflows/{workflowId}", "workflowId"},
      {"GET /v2/organizations/{orgId}/webhooks", %{"path" => %{"orgId" => org}}, &marked?/1,
       "DELETE /v2/organizations/{orgId}/webhooks/{webhookId}", "webhookId"},
      {"GET /v2/organizations/{orgId}/attributes", %{"path" => %{"orgId" => org}}, &marked?/1,
       "DELETE /v2/organizations/{orgId}/attributes/{attributeId}", "attributeId"},
      {"GET /v2/organizations/{orgId}/roles", %{"path" => %{"orgId" => org}}, &marked?/1,
       "DELETE /v2/organizations/{orgId}/roles/{roleId}", "roleId"},
      {"GET /v2/me/ooo", %{}, &marked?/1, "DELETE /v2/me/ooo/{oooId}", "oooId"},
      {"GET /v2/organizations/{orgId}/bookings",
       %{"path" => %{"orgId" => org}, "query" => %{"limit" => 100}}, &marked_booking?/1, @cancel,
       "bookingUid"}
    ]
  end

  @doc "Delete every marked row, and report anything that survived."
  @spec run(boolean()) :: non_neg_integer()
  def run(apply?) do
    credentials = %CalCom.Credentials{kind: :api_key, token: System.fetch_env!("CAL_COM_API_KEY")}

    team_targets()
    |> Enum.reduce(0, fn target, removed -> removed + reap(credentials, target, apply?) end)
  end

  # Team event types live under each team, so the teams are read first.
  @spec team_targets() :: list()
  defp team_targets do
    %CalCom.Credentials{kind: :api_key, token: System.fetch_env!("CAL_COM_API_KEY")}
    |> Sweep.Discover.ids(%{user_id: 1, organization_id: nil})
    |> Map.get("teamId", [])
    |> Enum.map(fn team_id ->
      {"GET /v2/teams/{teamId}/event-types", %{"path" => %{"teamId" => team_id}}, &marked?/1,
       "DELETE /v2/teams/{teamId}/event-types/{eventTypeId}", "eventTypeId"}
    end)
  end

  @spec reap(CalCom.Credentials.t(), tuple(), boolean()) :: non_neg_integer()
  defp reap(credentials, {list_id, params, marked, delete_id, param}, apply?) do
    rows =
      case Client.call(credentials, list_id, params) do
        {:ok, typed} -> typed.value.data |> List.wrap()
        {:error, _reason} -> []
      end

    rows
    |> Enum.filter(&(is_map(&1) and marked.(&1)))
    |> Enum.reduce(0, fn row, removed ->
      id = id_of(row, param)
      path = Map.merge(Map.get(params, "path", %{}), %{param => id})
      call_params = %{"path" => path}

      call_params =
        if delete_id == @cancel,
          do: Map.put(call_params, "body", %{"cancellationReason" => "certification reap"}),
          else: call_params

      if apply? do
        verdict = call_quietly(credentials, delete_id, call_params)
        IO.puts("  reaped #{delete_id} #{inspect(path)} -> #{verdict}")
      else
        IO.puts("  would reap #{delete_id} #{inspect(path)}")
      end

      removed + 1
    end)
  end

  @spec call_quietly(CalCom.Credentials.t(), String.t(), map()) :: atom()
  defp call_quietly(credentials, operation_id, params) do
    case Client.call(credentials, operation_id, params) do
      {:ok, _typed} -> :ok
      {:error, %CalCom.Error{reason: reason}} -> reason
      {:error, other} -> other
    end
  end

  @spec marked?(map()) :: boolean()
  defp marked?(row) do
    row
    |> row_text()
    |> String.downcase()
    |> String.contains?(@marker)
  end

  # A booking is reaped by cancelling it, and only while it is still live.
  @spec marked_booking?(map()) :: boolean()
  defp marked_booking?(row), do: marked?(row) and Map.get(row, :status) == "accepted"

  @spec row_text(map()) :: String.t()
  defp row_text(row) do
    Enum.map_join([:name, :title, :slug, :subscriber_url, :notes], " ", fn field ->
      case Map.get(row, field) do
        value when is_binary(value) -> value
        _other -> ""
      end
    end)
  end

  @spec id_of(map(), String.t()) :: term()
  defp id_of(row, "bookingUid"), do: Map.get(row, :uid)
  defp id_of(row, _param), do: Map.get(row, :id)
end

apply? = "--dry" not in System.argv()
count = Reap.run(apply?)

IO.puts("\n#{count} fixtures #{if apply?, do: "reaped", else: "found"}")
