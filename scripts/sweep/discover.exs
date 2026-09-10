defmodule Sweep.Discover do
  @moduledoc """
  Reads the ids an account owns off its own list endpoints, keyed by the path
  parameter each one fills, so a sweep can address every operation the account
  can actually reach.

  A parameter with no id is left out: the caller then calls the operation with
  an id that cannot name a real row and records the provider's answer as probe
  evidence rather than inventing a success.
  """

  alias CalCom.Credentials
  alias Sweep.Client

  @doc "The account the credentials belong to."
  @spec account(Credentials.t()) :: map()
  def account(credentials) do
    {:ok, me} = Client.call(credentials, "GET /v2/me", %{})
    %{user_id: me.value.data.id, organization_id: me.value.data.organization_id}
  end

  @doc "Every id the account owns, keyed by the path parameter it fills."
  @spec ids(Credentials.t(), map()) :: map()
  def ids(credentials, account) do
    organization = Enum.reject([account.organization_id], &is_nil/1)
    org = if organization == [], do: :none, else: %{"path" => %{"orgId" => hd(organization)}}

    %{"userId" => [account.user_id], "orgId" => organization}
    |> collect(credentials, "GET /v2/event-types", "eventTypeId", %{}, id())
    |> collect(credentials, "GET /v2/schedules", "scheduleId", %{}, id())
    |> collect(credentials, "GET /v2/teams", "teamId", %{}, id())
    |> collect(credentials, "GET /v2/organizations/{orgId}/teams", "teamId", org, id())
    |> collect(credentials, "GET /v2/bookings", "bookingUid", %{}, uid())
    |> collect(credentials, "GET /v2/organizations/{orgId}/bookings", "bookingUid", org, uid())
    |> collect(credentials, "GET /v2/webhooks", "webhookId", %{}, id())
    |> collect(credentials, "GET /v2/organizations/{orgId}/webhooks", "webhookId", org, id())
    |> collect(
      credentials,
      "GET /v2/organizations/{orgId}/memberships",
      "membershipId",
      org,
      id()
    )
    |> collect(credentials, "GET /v2/organizations/{orgId}/roles", "roleId", org, id())
    |> collect(credentials, "GET /v2/organizations/{orgId}/attributes", "attributeId", org, id())
    |> collect(
      credentials,
      "GET /v2/organizations/{orgId}/attributes",
      "attributeSlug",
      org,
      slug()
    )
    |> collect(
      credentials,
      "GET /v2/organizations/{orgId}/routing-forms",
      "routingFormId",
      org,
      id()
    )
    |> collect(
      credentials,
      "GET /v2/organizations/{orgId}/organizations",
      "managedOrganizationId",
      org,
      id()
    )
    |> collect(
      credentials,
      "GET /v2/organizations/{orgId}/delegation-credentials",
      "credentialId",
      org,
      id()
    )
    |> collect(credentials, "GET /v2/workflows", "workflowId", %{}, id())
    |> collect(credentials, "GET /v2/verified-resources/emails", "id", %{}, id())
    |> collect(credentials, "GET /v2/verified-resources/phones", "id", %{}, id())
    |> collect(credentials, "GET /v2/conferencing", "app", %{}, type())
    |> attendees(credentials)
  end

  @spec id() :: (term() -> [term()])
  defp id, do: &[Map.get(&1, :id)]
  @spec uid() :: (term() -> [term()])
  defp uid, do: &[Map.get(&1, :uid)]
  @spec slug() :: (term() -> [term()])
  defp slug, do: &[Map.get(&1, :slug)]
  @spec type() :: (term() -> [term()])
  defp type, do: &[Map.get(&1, :type)]

  # An attendee id only exists inside a booking, so it is read from the rows of
  # the first bookings that answer instead of from a list endpoint.
  @spec attendees(map(), Credentials.t()) :: map()
  defp attendees(discovered, credentials) do
    ids =
      discovered
      |> Map.get("bookingUid", [])
      |> Enum.take(3)
      |> Enum.flat_map(fn uid ->
        params = %{"path" => %{"bookingUid" => uid}}

        case Client.call(credentials, "GET /v2/bookings/{bookingUid}/attendees", params) do
          {:ok, typed} -> typed.value.data |> List.wrap() |> Enum.flat_map(id())
          _unavailable -> []
        end
      end)

    Map.update(discovered, "attendeeId", ids, &Enum.uniq(&1 ++ ids))
  end

  @spec collect(map(), Credentials.t(), String.t(), String.t(), map() | :none, (term() ->
                                                                                  [term()])) ::
          map()
  defp collect(discovered, _credentials, _id, _param, :none, _extract), do: discovered

  # `extract` names the row fields that fill the path parameter: a booking carries
  # both a numeric `id` and the `uid` the path wants, and an attribute carries an
  # id and a slug.
  defp collect(discovered, credentials, id, param, params, extract) do
    ids =
      case Client.call(credentials, id, params) do
        {:ok, typed} ->
          typed.value.data |> List.wrap() |> Enum.flat_map(extract) |> Enum.reject(&is_nil/1)

        _unavailable ->
          []
      end

    Map.update(discovered, param, ids, &Enum.uniq(&1 ++ ids))
  end
end
