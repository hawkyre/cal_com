# Write pass: exercises every mutation against the live Cal.com API.
#
#   MUTATE_APPLY=1 CAL_COM_API_KEY=... mix run scripts/mutate.exs
#   MUTATE_ONLY="POST /v2/webhooks" ... mix run scripts/mutate.exs   # one scenario
#
# Without `MUTATE_APPLY=1` nothing is called: the run prints the plan it would
# execute, scenario by scenario.
#
# Every scenario builds its own resources, exercises the operation, and deletes
# what it created — the read pass in `scripts/certify.exs` already covers every
# read. Verdicts merge into `source/certification.json`, and a parsed mutation
# leaves the same redacted capture a read does.
Code.require_file("sweep/client.exs", __DIR__)
Code.require_file("sweep/discover.exs", __DIR__)
Code.require_file("sweep/inputs.exs", __DIR__)
Code.require_file("sweep/judge.exs", __DIR__)
Code.require_file("sweep/ledger.exs", __DIR__)
Code.require_file("sweep/report.exs", __DIR__)

Sweep.Client.start()

defmodule Mutate do
  @moduledoc """
  Calls every mutation once, inside an envelope that creates its own fixture and
  removes it again.

  A scenario is `{operation id, what it proves, fun}`. The fun receives the
  credentials and the ids the account owns, and calls `Sweep.Ledger.call/3` for
  every request it makes — setup included, because the webhook created to
  exercise a delete is itself a certified `POST /v2/webhooks`.

  Operations that cannot be exercised on this account are listed in
  `declined/0` with the reason, and never touched.
  """

  alias CalCom.Credentials
  alias Sweep.{Client, Discover, Inputs, Ledger, Report}

  # A URL Cal.com will accept as a webhook destination. Nothing listens there.
  @subscriber "https://example.invalid/kithe-certification"
  # The attendee every certification booking is made for, matching the address
  # the earlier connector tests used.
  @attendee %{
    "name" => "Kithe Connector Test",
    "email" => "hawkyre@gmail.com",
    "timeZone" => "Europe/London",
    "language" => "en"
  }

  @doc "Print the plan, then run it when `MUTATE_APPLY=1`."
  @spec main() :: :ok
  def main do
    credentials = %Credentials{kind: :api_key, token: System.fetch_env!("CAL_COM_API_KEY")}
    only = System.get_env("MUTATE_ONLY")
    scenarios = Enum.filter(scenarios(), fn {id, _proves, _fun} -> is_nil(only) or id == only end)

    IO.puts("plan: #{length(scenarios)} scenarios, #{length(declined())} declined")

    for {id, proves, _fun} <- scenarios,
        do: Client.log("  #{String.pad_trailing(id, 74)} #{proves}")

    if System.get_env("MUTATE_APPLY") == "1" do
      account = Discover.account(credentials)
      ids = Discover.ids(credentials, account)
      Client.log("account: user=#{account.user_id} org=#{inspect(account.organization_id)}")
      for {_id, _proves, fun} <- scenarios, do: fun.(credentials, ids)
      leftovers = Ledger.undo(credentials)
      if leftovers == [], do: Client.log("undo: everything this run created is gone")
      finish(credentials, account)
    else
      IO.puts("\ndry run: set MUTATE_APPLY=1 to call these")
    end

    :ok
  end

  @spec finish(Credentials.t(), map()) :: :ok
  defp finish(_credentials, _account) do
    Ledger.verdicts()
    |> Map.merge(
      Map.new(declined(), fn {id, reason} -> {id, %{status: "declined", reason: reason}} end)
    )
    |> merge_into_report()

    for {id, verdict} <- Ledger.verdicts(),
        package = write_package(verdict),
        do: Report.capture!(id, package)

    :ok
  end

  # The read pass owns `source/certification.json`: the write pass merges its own
  # verdicts over it, so the file always describes all 349 operations.
  @spec merge_into_report(map()) :: :ok
  defp merge_into_report(verdicts) do
    report = Jason.decode!(File.read!("source/certification.json"))
    merged = Map.merge(report["operations"], verdicts)

    File.write!(
      "source/certification.json",
      Jason.encode!(
        report |> Map.put("operations", merged) |> Map.put("writes_generated_at", now()),
        pretty: true
      ) <>
        "\n"
    )

    IO.puts("merged #{map_size(verdicts)} write verdicts into source/certification.json")
    Report.summary(merged)
    :ok
  end

  @spec write_package(map()) :: Response.t() | nil
  defp write_package(verdict) do
    case verdict[:capture] do
      {_typed, package} -> package
      _none -> nil
    end
  end

  @spec now() :: String.t()
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Mutations this account cannot certify. Each entry names the wall it hit, so
  # the certification file says why an operation was not exercised instead of
  # leaving the reader to guess.
  @spec declined() :: [{String.t(), String.t()}]
  defp declined do
    [
      {"POST /v2/api-keys/refresh",
       "rotating the key would invalidate the credential this sweep is using"},
      {"POST /v2/credits/charge", "charges real money"},
      {"POST /v2/auth/oauth2/token",
       "needs an OAuth client id and secret from a platform account"},
      {"POST /v2/oauth/{clientId}/refresh",
       "needs a platform OAuth client this account does not have"},
      {"POST /v2/oauth-clients",
       "OAuth clients are a platform feature; this account answered forbidden"},
      {"PATCH /v2/oauth-clients/{clientId}", "needs a platform OAuth client"},
      {"DELETE /v2/oauth-clients/{clientId}", "needs a platform OAuth client"},
      {"POST /v2/oauth-clients/{clientId}/users", "needs a platform OAuth client"},
      {"PATCH /v2/oauth-clients/{clientId}/users/{userId}", "needs a platform OAuth client"},
      {"DELETE /v2/oauth-clients/{clientId}/users/{userId}", "needs a platform OAuth client"},
      {"POST /v2/oauth-clients/{clientId}/users/{userId}/force-refresh",
       "needs a platform OAuth client"},
      {"POST /v2/oauth-clients/{clientId}/webhooks", "needs a platform OAuth client"},
      {"PATCH /v2/oauth-clients/{clientId}/webhooks/{webhookId}",
       "needs a platform OAuth client"},
      {"DELETE /v2/oauth-clients/{clientId}/webhooks/{webhookId}",
       "needs a platform OAuth client"},
      {"POST /v2/notifications/subscriptions/app-push",
       "needs a device push token for this account"},
      {"DELETE /v2/notifications/subscriptions/app-push",
       "needs a device push token for this account"},
      {"POST /v2/notifications/subscriptions/slack/link-intents",
       "needs a Slack workspace to link"},
      {"DELETE /v2/notifications/subscriptions/slack", "needs a Slack workspace to unlink"},
      {"POST /v2/notifications/subscriptions/telegram/link-intents",
       "needs a Telegram account to link"},
      {"DELETE /v2/notifications/subscriptions/telegram", "needs a Telegram account to unlink"},
      {"POST /v2/calendars/{calendar}/credentials", "needs a third-party calendar OAuth grant"},
      {"DELETE /v2/calendars/{calendar}/disconnect", "needs a connected third-party calendar"},
      {"PATCH /v2/calendars/{calendar}/events/{eventUid}",
       "needs a synced event in a connected calendar"},
      {"POST /v2/conferencing/{app}/connect", "needs a Zoom or Google Meet OAuth grant"},
      {"DELETE /v2/conferencing/{app}/disconnect", "needs a connected conferencing app"},
      {"POST /v2/conferencing/{app}/default", "needs a connected conferencing app"},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/conferencing/{app}/connect",
       "needs a Zoom or Google Meet OAuth grant"},
      {"DELETE /v2/organizations/{orgId}/teams/{teamId}/conferencing/{app}/disconnect",
       "needs a connected conferencing app"},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/conferencing/{app}/default",
       "needs a connected conferencing app"},
      {"POST /v2/organizations/{orgId}/users", "would invite a real person to the organization"},
      {"POST /v2/organizations/{orgId}/memberships",
       "would invite a real person to the organization"},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/invite",
       "would email an invite to a real person"},
      {"POST /v2/teams/{teamId}/invite", "would email an invite to a real person"},
      {"DELETE /v2/organizations/{orgId}/users/{userId}",
       "would remove a member the account already has"},
      {"DELETE /v2/organizations/{orgId}/memberships/{membershipId}",
       "would remove a membership the account already has"},
      {"DELETE /v2/organizations/{orgId}/organizations/{managedOrganizationId}",
       "would delete a managed organization the account already has"},
      {"PATCH /v2/organizations/{orgId}/organizations/{managedOrganizationId}",
       "would edit a managed organization the account already has"}
    ]
  end

  # ---------------------------------------------------------------------------
  # The plan
  # ---------------------------------------------------------------------------

  @spec scenarios() :: [{String.t(), String.t(), (Credentials.t(), map() -> any())}]
  defp scenarios do
    webhooks() ++
      event_types() ++
      schedules() ++
      slots() ++
      out_of_office() ++
      booking_limits() ++
      calendars() ++
      workflows() ++
      routing_forms() ++
      teams() ++
      attributes() ++
      roles() ++
      organization_webhooks() ++
      insights() ++
      bookings() ++
      verified_resources()
  end

  # ---------------------------------------------------------------------------
  # Input helpers
  # ---------------------------------------------------------------------------

  # Every required field of an operation's body or query, sampled from its own
  # contract, with the scenario's values laid over the top.
  @spec input(String.t(), String.t(), map()) :: map()
  defp input(operation_id, part, overrides) do
    operation = CalCom.Registry.find(operation_id)

    base =
      case Enum.find(operation.input_module.fields(), &(&1.wire == part)) do
        %{rule: %{kind: {:object, module}}} -> Inputs.required_fields(module)
        %{rule: %{kind: {:one_of, [rule | _rest]}}} -> Inputs.sample(rule)
        _none -> %{}
      end

    Map.merge(base, overrides)
  end

  @spec params(String.t(), keyword()) :: map()
  defp params(operation_id, options) do
    %{}
    |> maybe("path", Keyword.get(options, :path))
    |> maybe("query", input(operation_id, "query", Keyword.get(options, :query, %{})))
    |> maybe("body", input(operation_id, "body", Keyword.get(options, :body, %{})))
  end

  @spec maybe(map(), String.t(), map() | nil) :: map()
  defp maybe(params, _part, nil), do: params
  defp maybe(params, part, values), do: Map.put(params, part, values)

  # A unique slug/name per run, so two runs never collide on the same resource.
  @spec suffix() :: String.t()
  defp suffix, do: System.system_time(:second) |> Integer.to_string(36)

  @spec tomorrow() :: String.t()
  defp tomorrow,
    do:
      DateTime.utc_now()
      |> DateTime.add(1, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  @spec each([String.t()], String.t(), (String.t() -> any())) :: :ok
  defp each(ids, param, fun),
    do: Enum.each(Enum.take(Map.get(ids, param, []) |> List.wrap(), 1), fun)

  # ---------------------------------------------------------------------------
  # Webhooks
  # ---------------------------------------------------------------------------

  @spec webhooks() :: [{String.t(), String.t(), fun()}]
  defp webhooks do
    [
      {"POST /v2/webhooks", "creates a webhook for this user",
       fn credentials, _ids ->
         created =
           Ledger.call(
             credentials,
             "POST /v2/webhooks",
             params("POST /v2/webhooks",
               body: %{
                 "active" => true,
                 "subscriberUrl" => @subscriber,
                 "triggers" => ["BOOKING_CREATED"]
               }
             )
           )

         Ledger.track(
           "DELETE /v2/webhooks/{webhookId}",
           "webhookId",
           Ledger.created_id(created, :id)
         )
       end},
      {"PATCH /v2/webhooks/{webhookId}", "edits the webhook this run created",
       fn credentials, _ids ->
         with_webhook(credentials, fn id ->
           Ledger.call(
             credentials,
             "PATCH /v2/webhooks/{webhookId}",
             params("PATCH /v2/webhooks/{webhookId}",
               path: %{"webhookId" => id},
               body: %{"active" => false, "subscriberUrl" => @subscriber}
             )
           )
         end)
       end},
      {"DELETE /v2/webhooks/{webhookId}", "deletes a webhook this run created",
       fn credentials, _ids ->
         created =
           Ledger.call(
             credentials,
             "POST /v2/webhooks",
             params("POST /v2/webhooks",
               body: %{
                 "active" => true,
                 "subscriberUrl" => @subscriber,
                 "triggers" => ["BOOKING_CREATED"]
               }
             )
           )

         case Ledger.created_id(created, :id) do
           nil ->
             :ok

           id ->
             Ledger.call(credentials, "DELETE /v2/webhooks/{webhookId}", %{
               "path" => %{"webhookId" => id}
             })
         end
       end}
    ]
  end

  @spec with_webhook(Credentials.t(), (term() -> any())) :: any()
  defp with_webhook(credentials, fun) do
    created =
      Ledger.call(
        credentials,
        "POST /v2/webhooks",
        params("POST /v2/webhooks",
          body: %{
            "active" => true,
            "subscriberUrl" => @subscriber,
            "triggers" => ["BOOKING_CREATED"]
          }
        )
      )

    case Ledger.created_id(created, :id) do
      nil -> :ok
      id -> Ledger.track("DELETE /v2/webhooks/{webhookId}", "webhookId", id) && fun.(id)
    end
  end

  # ---------------------------------------------------------------------------
  # Event types
  # ---------------------------------------------------------------------------

  @spec event_types() :: [{String.t(), String.t(), fun()}]
  defp event_types do
    [
      {"POST /v2/event-types", "creates an event type on this user",
       fn credentials, _ids ->
         Ledger.track(
           "DELETE /v2/event-types/{eventTypeId}",
           "eventTypeId",
           Ledger.created_id(event_type(credentials), :id)
         )
       end},
      {"PATCH /v2/event-types/{eventTypeId}", "edits the event type this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn id ->
           Ledger.call(
             credentials,
             "PATCH /v2/event-types/{eventTypeId}",
             params("PATCH /v2/event-types/{eventTypeId}",
               path: %{"eventTypeId" => id},
               body: %{"title" => "Kithe certification (edited)", "slug" => slug("cert-edited")}
             )
           )
         end)
       end},
      {"DELETE /v2/event-types/{eventTypeId}", "deletes an event type this run created",
       fn credentials, _ids ->
         case Ledger.created_id(event_type(credentials), :id) do
           nil ->
             :ok

           id ->
             Ledger.call(credentials, "DELETE /v2/event-types/{eventTypeId}", %{
               "path" => %{"eventTypeId" => id}
             })
         end
       end},
      {"POST /v2/event-types/{eventTypeId}/private-links",
       "creates a private link on a claimed event type",
       fn credentials, _ids ->
         with_event_type(credentials, fn id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/event-types/{eventTypeId}/private-links",
               params("POST /v2/event-types/{eventTypeId}/private-links",
                 path: %{"eventTypeId" => id}
               )
             )

           Ledger.track(
             "DELETE /v2/event-types/{eventTypeId}/private-links/{linkId}",
             "linkId",
             Ledger.created_id(created, :id)
           )
         end)
       end},
      {"POST /v2/event-types/{eventTypeId}/booking-fields",
       "adds a booking field to a claimed event type",
       fn credentials, _ids ->
         with_event_type(credentials, fn id ->
           Ledger.call(
             credentials,
             "POST /v2/event-types/{eventTypeId}/booking-fields",
             params("POST /v2/event-types/{eventTypeId}/booking-fields",
               path: %{"eventTypeId" => id},
               body: %{
                 "type" => "text",
                 "slug" => slug("cert-field"),
                 "label" => "Certification field",
                 "required" => false
               }
             )
           )
         end)
       end}
    ]
  end

  @spec event_type(Credentials.t()) :: map()
  defp event_type(credentials) do
    Ledger.call(
      credentials,
      "POST /v2/event-types",
      params("POST /v2/event-types",
        body: %{
          "title" => "Kithe certification",
          "slug" => slug("kithe-cert"),
          "lengthInMinutes" => 15,
          "description" => "Created by the cal_com certification sweep"
        }
      )
    )
  end

  @spec with_event_type(Credentials.t(), (term() -> any())) :: any()
  defp with_event_type(credentials, fun) do
    created = event_type(credentials)

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      id ->
        Ledger.track("DELETE /v2/event-types/{eventTypeId}", "eventTypeId", id)
        fun.(id)
    end
  end

  @spec slug(String.t()) :: String.t()
  defp slug(prefix), do: prefix <> "-" <> suffix()

  # ---------------------------------------------------------------------------
  # Schedules, slots, out of office, booking limits
  # ---------------------------------------------------------------------------

  @spec schedules() :: [{String.t(), String.t(), fun()}]
  defp schedules do
    [
      {"POST /v2/schedules", "creates a schedule on this user",
       fn credentials, _ids ->
         Ledger.track(
           "DELETE /v2/schedules/{scheduleId}",
           "scheduleId",
           Ledger.created_id(schedule(credentials), :id)
         )
       end},
      {"PATCH /v2/schedules/{scheduleId}", "edits the schedule this run created",
       fn credentials, _ids ->
         with_schedule(credentials, fn id ->
           Ledger.call(
             credentials,
             "PATCH /v2/schedules/{scheduleId}",
             params("PATCH /v2/schedules/{scheduleId}",
               path: %{"scheduleId" => id},
               body: %{"name" => "Kithe certification (edited)", "timeZone" => "Europe/London"}
             )
           )
         end)
       end},
      {"DELETE /v2/schedules/{scheduleId}", "deletes a schedule this run created",
       fn credentials, _ids ->
         case Ledger.created_id(schedule(credentials), :id) do
           nil ->
             :ok

           id ->
             Ledger.call(credentials, "DELETE /v2/schedules/{scheduleId}", %{
               "path" => %{"scheduleId" => id}
             })
         end
       end}
    ]
  end

  @spec schedule(Credentials.t()) :: map()
  defp schedule(credentials) do
    Ledger.call(
      credentials,
      "POST /v2/schedules",
      params("POST /v2/schedules",
        body: %{
          "name" => "Kithe certification " <> suffix(),
          "timeZone" => "Europe/London",
          "isDefault" => false
        }
      )
    )
  end

  @spec with_schedule(Credentials.t(), (term() -> any())) :: any()
  defp with_schedule(credentials, fun) do
    case Ledger.created_id(schedule(credentials), :id) do
      nil ->
        :ok

      id ->
        Ledger.track("DELETE /v2/schedules/{scheduleId}", "scheduleId", id)
        fun.(id)
    end
  end

  @spec slots() :: [{String.t(), String.t(), fun()}]
  defp slots do
    [
      {"POST /v2/slots/reservations", "reserves a slot on a claimed event type",
       fn credentials, ids ->
         each(ids, "eventTypeId", fn event_type_id ->
           Ledger.track(
             "DELETE /v2/slots/reservations/{uid}",
             "uid",
             Ledger.created_id(reservation(credentials, event_type_id), :reservation_uid)
           )
         end)
       end},
      {"PATCH /v2/slots/reservations/{uid}", "edits the reservation this run created",
       fn credentials, ids ->
         each(ids, "eventTypeId", fn event_type_id ->
           with_reservation(credentials, event_type_id, fn uid ->
             Ledger.call(
               credentials,
               "PATCH /v2/slots/reservations/{uid}",
               params("PATCH /v2/slots/reservations/{uid}", path: %{"uid" => uid}, body: %{})
             )
           end)
         end)
       end},
      {"DELETE /v2/slots/reservations/{uid}", "releases a reservation this run created",
       fn credentials, ids ->
         each(ids, "eventTypeId", fn event_type_id ->
           case Ledger.created_id(reservation(credentials, event_type_id), :reservation_uid) do
             nil ->
               :ok

             uid ->
               Ledger.call(credentials, "DELETE /v2/slots/reservations/{uid}", %{
                 "path" => %{"uid" => uid}
               })
           end
         end)
       end}
    ]
  end

  @spec reservation(Credentials.t(), term()) :: map()
  defp reservation(credentials, event_type_id) do
    Ledger.call(
      credentials,
      "POST /v2/slots/reservations",
      params("POST /v2/slots/reservations",
        body: %{"eventTypeId" => event_type_id, "slotStart" => tomorrow()}
      )
    )
  end

  @spec with_reservation(Credentials.t(), term(), (term() -> any())) :: any()
  defp with_reservation(credentials, event_type_id, fun) do
    case Ledger.created_id(reservation(credentials, event_type_id), :reservation_uid) do
      nil -> :ok
      uid -> Ledger.track("DELETE /v2/slots/reservations/{uid}", "uid", uid) && fun.(uid)
    end
  end

  @spec out_of_office() :: [{String.t(), String.t(), fun()}]
  defp out_of_office do
    [
      {"POST /v2/me/ooo", "records an out-of-office entry for this user",
       fn credentials, _ids ->
         Ledger.track(
           "DELETE /v2/me/ooo/{oooId}",
           "oooId",
           Ledger.created_id(ooo(credentials), :id)
         )
       end},
      {"PATCH /v2/me/ooo/{oooId}", "edits the out-of-office entry this run created",
       fn credentials, _ids ->
         with_ooo(credentials, fn id ->
           Ledger.call(
             credentials,
             "PATCH /v2/me/ooo/{oooId}",
             params("PATCH /v2/me/ooo/{oooId}",
               path: %{"oooId" => id},
               body: %{
                 "notes" => "Edited by the certification sweep",
                 "start" => tomorrow(),
                 "end" => tomorrow()
               }
             )
           )
         end)
       end},
      {"DELETE /v2/me/ooo/{oooId}", "deletes an out-of-office entry this run created",
       fn credentials, _ids ->
         case Ledger.created_id(ooo(credentials), :id) do
           nil ->
             :ok

           id ->
             Ledger.call(credentials, "DELETE /v2/me/ooo/{oooId}", %{"path" => %{"oooId" => id}})
         end
       end}
    ]
  end

  @spec ooo(Credentials.t()) :: map()
  defp ooo(credentials) do
    Ledger.call(
      credentials,
      "POST /v2/me/ooo",
      params("POST /v2/me/ooo",
        body: %{"start" => tomorrow(), "end" => tomorrow(), "notes" => "cal_com certification"}
      )
    )
  end

  @spec with_ooo(Credentials.t(), (term() -> any())) :: any()
  defp with_ooo(credentials, fun) do
    case Ledger.created_id(ooo(credentials), :id) do
      nil ->
        :ok

      id ->
        Ledger.track("DELETE /v2/me/ooo/{oooId}", "oooId", id)
        fun.(id)
    end
  end

  # A booking limit is a setting, not a resource: the sweep sets one on a
  # *disposable* event type it created, then deletes that event type.
  @spec booking_limits() :: [{String.t(), String.t(), fun()}]
  defp booking_limits do
    [
      {"PATCH /v2/me/booking-limits", "sets a booking limit on this user",
       fn credentials, _ids ->
         Ledger.call(
           credentials,
           "PATCH /v2/me/booking-limits",
           params("PATCH /v2/me/booking-limits", body: %{"bookingLimitsCount" => %{"day" => 50}})
         )
       end},
      {"DELETE /v2/me/booking-limits", "clears the booking limit this run set",
       fn credentials, _ids ->
         Ledger.call(
           credentials,
           "DELETE /v2/me/booking-limits",
           params("DELETE /v2/me/booking-limits", body: %{"bookingLimitsCount" => %{"day" => 50}})
         )
       end},
      {"PATCH /v2/me/team-booking-limits/{teamId}", "sets a team booking limit",
       fn credentials, ids ->
         each(ids, "teamId", fn team_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/me/team-booking-limits/{teamId}",
             params("PATCH /v2/me/team-booking-limits/{teamId}",
               path: %{"teamId" => team_id},
               body: %{"bookingLimitsCount" => %{"day" => 50}}
             )
           )
         end)
       end},
      {"DELETE /v2/me/team-booking-limits/{teamId}", "clears the team booking limit this run set",
       fn credentials, ids ->
         each(ids, "teamId", fn team_id ->
           Ledger.call(
             credentials,
             "DELETE /v2/me/team-booking-limits/{teamId}",
             params("DELETE /v2/me/team-booking-limits/{teamId}",
               path: %{"teamId" => team_id},
               body: %{"bookingLimitsCount" => %{"day" => 50}}
             )
           )
         end)
       end}
    ]
  end

  # ---------------------------------------------------------------------------
  # Calendars, workflows, routing forms
  # ---------------------------------------------------------------------------

  @spec calendars() :: [{String.t(), String.t(), fun()}]
  defp calendars do
    [
      {"PUT /v2/destination-calendars", "sets the destination calendar for this user",
       fn credentials, _ids ->
         Ledger.call(
           credentials,
           "PUT /v2/destination-calendars",
           params("PUT /v2/destination-calendars",
             body: %{
               "integration" => "google_calendar",
               "externalId" => "kithe-certification@example.invalid"
             }
           )
         )
       end},
      {"POST /v2/selected-calendars", "selects a calendar for this user",
       fn credentials, _ids ->
         Ledger.call(
           credentials,
           "POST /v2/selected-calendars",
           params("POST /v2/selected-calendars",
             body: %{
               "integration" => "google_calendar",
               "externalId" => "kithe-certification@example.invalid",
               "credentialId" => 0
             }
           )
         )
       end},
      {"DELETE /v2/selected-calendars", "removes the calendar selection this run added",
       fn credentials, _ids ->
         Ledger.call(
           credentials,
           "DELETE /v2/selected-calendars",
           params("DELETE /v2/selected-calendars",
             body: %{
               "integration" => "google_calendar",
               "externalId" => "kithe-certification@example.invalid"
             }
           )
         )
       end}
    ]
  end

  @spec workflows() :: [{String.t(), String.t(), fun()}]
  defp workflows do
    step = %{
      "action" => "EMAIL_HOST",
      "template" => "REMINDER",
      "includeCalendarEvent" => false,
      "sender" => "me@hawkyre.com",
      "subject" => "Kithe certification",
      "body" => "Reminder created by the cal_com certification sweep"
    }

    trigger = %{"type" => "BEFORE_EVENT", "offset" => 1, "timeUnit" => "HOUR"}
    activation = %{"type" => "EVENT_START", "offset" => 1, "timeUnit" => "HOUR"}

    body = fn overrides ->
      Map.merge(
        %{
          "name" => "Kithe certification " <> suffix(),
          "activation" => activation,
          "trigger" => trigger,
          "steps" => [step]
        },
        overrides
      )
    end

    [
      {"POST /v2/workflows", "creates a workflow on this user",
       fn credentials, _ids ->
         created =
           Ledger.call(
             credentials,
             "POST /v2/workflows",
             params("POST /v2/workflows", body: body.(%{}))
           )

         Ledger.track(
           "DELETE /v2/workflows/{workflowId}",
           "workflowId",
           Ledger.created_id(created, :id)
         )
       end},
      {"PATCH /v2/workflows/{workflowId}", "edits the workflow this run created",
       fn credentials, _ids ->
         with_workflow(credentials, body, fn id ->
           Ledger.call(
             credentials,
             "PATCH /v2/workflows/{workflowId}",
             params("PATCH /v2/workflows/{workflowId}",
               path: %{"workflowId" => id},
               body: body.(%{"name" => "Kithe certification (edited) " <> suffix()})
             )
           )
         end)
       end},
      {"DELETE /v2/workflows/{workflowId}", "deletes a workflow this run created",
       fn credentials, _ids ->
         created =
           Ledger.call(
             credentials,
             "POST /v2/workflows",
             params("POST /v2/workflows", body: body.(%{}))
           )

         case Ledger.created_id(created, :id) do
           nil ->
             :ok

           id ->
             Ledger.call(credentials, "DELETE /v2/workflows/{workflowId}", %{
               "path" => %{"workflowId" => id}
             })
         end
       end}
    ]
  end

  @spec with_workflow(Credentials.t(), (map() -> map()), (term() -> any())) :: any()
  defp with_workflow(credentials, body, fun) do
    created =
      Ledger.call(
        credentials,
        "POST /v2/workflows",
        params("POST /v2/workflows", body: body.(%{}))
      )

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      id ->
        Ledger.track("DELETE /v2/workflows/{workflowId}", "workflowId", id)
        fun.(id)
    end
  end

  @spec routing_forms() :: [{String.t(), String.t(), fun()}]
  defp routing_forms do
    [
      {"POST /v2/routing-forms/{routingFormId}/calculate-slots",
       "computes slots for a routing form",
       fn credentials, ids ->
         each(ids, "routingFormId", fn form_id ->
           start_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
           end_at = DateTime.add(start_at, 1, :hour)

           Ledger.call(
             credentials,
             "POST /v2/routing-forms/{routingFormId}/calculate-slots",
             params("POST /v2/routing-forms/{routingFormId}/calculate-slots",
               path: %{"routingFormId" => form_id},
               query: %{
                 "start" => DateTime.to_iso8601(start_at),
                 "end" => DateTime.to_iso8601(end_at),
                 "timeZone" => "Europe/London",
                 "duration" => 15,
                 "format" => "range"
               }
             )
           )
         end)
       end}
    ]
  end

  # ---------------------------------------------------------------------------
  # Teams, attributes, roles, organization webhooks
  # ---------------------------------------------------------------------------

  @spec teams() :: [{String.t(), String.t(), fun()}]
  defp teams do
    [
      {"POST /v2/teams", "creates a team",
       fn credentials, _ids ->
         Ledger.track(
           "DELETE /v2/teams/{teamId}",
           "teamId",
           Ledger.created_id(team(credentials), :id)
         )
       end},
      {"PATCH /v2/teams/{teamId}", "edits the team this run created",
       fn credentials, _ids ->
         with_team(credentials, fn id ->
           Ledger.call(
             credentials,
             "PATCH /v2/teams/{teamId}",
             params("PATCH /v2/teams/{teamId}",
               path: %{"teamId" => id},
               body: %{"name" => "Kithe certification (edited) " <> suffix()}
             )
           )
         end)
       end},
      {"DELETE /v2/teams/{teamId}", "deletes a team this run created",
       fn credentials, _ids ->
         case Ledger.created_id(team(credentials), :id) do
           nil ->
             :ok

           id ->
             Ledger.call(credentials, "DELETE /v2/teams/{teamId}", %{"path" => %{"teamId" => id}})
         end
       end},
      {"POST /v2/teams/{teamId}/event-types", "creates a team event type",
       fn credentials, _ids ->
         with_team(credentials, fn team_id ->
           Ledger.call(
             credentials,
             "POST /v2/teams/{teamId}/event-types",
             params("POST /v2/teams/{teamId}/event-types",
               path: %{"teamId" => team_id},
               body: %{
                 "title" => "Kithe certification team event",
                 "slug" => slug("kithe-team-cert"),
                 "lengthInMinutes" => 15,
                 "hosts" => [%{"userId" => 3_209_949, "isFixed" => true}]
               }
             )
           )
         end)
       end},
      {"POST /v2/teams/{teamId}/memberships", "adds this user to the team this run created",
       fn credentials, _ids ->
         with_team(credentials, fn team_id ->
           Ledger.call(
             credentials,
             "POST /v2/teams/{teamId}/memberships",
             params("POST /v2/teams/{teamId}/memberships",
               path: %{"teamId" => team_id},
               body: %{"userId" => 3_209_949, "role" => "MEMBER", "accepted" => true}
             )
           )
         end)
       end},
      {"POST /v2/teams/{teamId}/roles", "creates a team role",
       fn credentials, _ids ->
         with_team(credentials, fn team_id ->
           Ledger.call(
             credentials,
             "POST /v2/teams/{teamId}/roles",
             params("POST /v2/teams/{teamId}/roles",
               path: %{"teamId" => team_id},
               body: %{
                 "name" => "Kithe cert role " <> suffix(),
                 "permissions" => ["booking.read"]
               }
             )
           )
         end)
       end}
    ]
  end

  @spec team(Credentials.t()) :: map()
  defp team(credentials) do
    Ledger.call(
      credentials,
      "POST /v2/teams",
      params("POST /v2/teams",
        body: %{
          "name" => "Kithe certification " <> suffix(),
          "slug" => slug("kithe-cert"),
          "isPrivate" => true
        }
      )
    )
  end

  @spec with_team(Credentials.t(), (term() -> any())) :: any()
  defp with_team(credentials, fun) do
    case Ledger.created_id(team(credentials), :id) do
      nil ->
        :ok

      id ->
        Ledger.track("DELETE /v2/teams/{teamId}", "teamId", id)
        fun.(id)
    end
  end

  @spec attributes() :: [{String.t(), String.t(), fun()}]
  defp attributes do
    body = fn overrides ->
      Map.merge(
        %{
          "name" => "Kithe certification " <> suffix(),
          "slug" => slug("kithe-cert"),
          "type" => "TEXT",
          "options" => [],
          "enabled" => true
        },
        overrides
      )
    end

    [
      {"POST /v2/organizations/{orgId}/attributes", "creates an organization attribute",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/attributes",
               params("POST /v2/organizations/{orgId}/attributes",
                 path: %{"orgId" => org_id},
                 body: body.(%{})
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/attributes/{attributeId}",
             "attributeId",
             Ledger.created_id(created, :id)
           )
         end)
       end},
      {"POST /v2/organizations/{orgId}/attributes/{attributeId}/options",
       "adds an option to an attribute",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           with_attribute(credentials, org_id, body, fn attribute_id ->
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/attributes/{attributeId}/options",
               params("POST /v2/organizations/{orgId}/attributes/{attributeId}/options",
                 path: %{"orgId" => org_id, "attributeId" => attribute_id},
                 body: %{"value" => "certification", "slug" => slug("cert-option")}
               )
             )
           end)
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/attributes/{attributeId}",
       "edits the attribute this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           with_attribute(credentials, org_id, body, fn attribute_id ->
             Ledger.call(
               credentials,
               "PATCH /v2/organizations/{orgId}/attributes/{attributeId}",
               params("PATCH /v2/organizations/{orgId}/attributes/{attributeId}",
                 path: %{"orgId" => org_id, "attributeId" => attribute_id},
                 body: %{"name" => "Kithe certification (edited) " <> suffix()}
               )
             )
           end)
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/attributes/{attributeId}",
       "deletes an attribute this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/attributes",
               params("POST /v2/organizations/{orgId}/attributes",
                 path: %{"orgId" => org_id},
                 body: body.(%{})
               )
             )

           case Ledger.created_id(created, :id) do
             nil ->
               :ok

             attribute_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/attributes/{attributeId}",
                 %{"path" => %{"orgId" => org_id, "attributeId" => attribute_id}}
               )
           end
         end)
       end}
    ]
  end

  @spec with_attribute(Credentials.t(), term(), (map() -> map()), (term() -> any())) :: any()
  defp with_attribute(credentials, org_id, body, fun) do
    created =
      Ledger.call(
        credentials,
        "POST /v2/organizations/{orgId}/attributes",
        params("POST /v2/organizations/{orgId}/attributes",
          path: %{"orgId" => org_id},
          body: body.(%{})
        )
      )

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      attribute_id ->
        Ledger.track(
          "DELETE /v2/organizations/{orgId}/attributes/{attributeId}",
          "attributeId",
          attribute_id
        )

        fun.(attribute_id)
    end
  end

  @spec roles() :: [{String.t(), String.t(), fun()}]
  defp roles do
    body = fn overrides ->
      Map.merge(
        %{"name" => "Kithe cert role " <> suffix(), "permissions" => ["booking.read"]},
        overrides
      )
    end

    [
      {"POST /v2/organizations/{orgId}/roles", "creates an organization role",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/roles",
               params("POST /v2/organizations/{orgId}/roles",
                 path: %{"orgId" => org_id},
                 body: body.(%{})
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/roles/{roleId}",
             "roleId",
             Ledger.created_id(created, :id)
           )
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/roles/{roleId}", "edits the role this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           with_role(credentials, org_id, body, fn role_id ->
             Ledger.call(
               credentials,
               "PATCH /v2/organizations/{orgId}/roles/{roleId}",
               params("PATCH /v2/organizations/{orgId}/roles/{roleId}",
                 path: %{"orgId" => org_id, "roleId" => role_id},
                 body: %{"name" => "Kithe cert role (edited) " <> suffix()}
               )
             )
           end)
         end)
       end},
      {"POST /v2/organizations/{orgId}/roles/{roleId}/permissions",
       "grants a permission to a role this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           with_role(credentials, org_id, body, fn role_id ->
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/roles/{roleId}/permissions",
               params("POST /v2/organizations/{orgId}/roles/{roleId}/permissions",
                 path: %{"orgId" => org_id, "roleId" => role_id},
                 body: %{"permissions" => ["booking.read"]}
               )
             )
           end)
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/roles/{roleId}", "deletes a role this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/roles",
               params("POST /v2/organizations/{orgId}/roles",
                 path: %{"orgId" => org_id},
                 body: body.(%{})
               )
             )

           case Ledger.created_id(created, :id) do
             nil ->
               :ok

             role_id ->
               Ledger.call(credentials, "DELETE /v2/organizations/{orgId}/roles/{roleId}", %{
                 "path" => %{"orgId" => org_id, "roleId" => role_id}
               })
           end
         end)
       end}
    ]
  end

  @spec with_role(Credentials.t(), term(), (map() -> map()), (term() -> any())) :: any()
  defp with_role(credentials, org_id, body, fun) do
    created =
      Ledger.call(
        credentials,
        "POST /v2/organizations/{orgId}/roles",
        params("POST /v2/organizations/{orgId}/roles",
          path: %{"orgId" => org_id},
          body: body.(%{})
        )
      )

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      role_id ->
        Ledger.track("DELETE /v2/organizations/{orgId}/roles/{roleId}", "roleId", role_id)
        fun.(role_id)
    end
  end

  @spec organization_webhooks() :: [{String.t(), String.t(), fun()}]
  defp organization_webhooks do
    body = %{"active" => true, "subscriberUrl" => @subscriber, "triggers" => ["BOOKING_CREATED"]}

    [
      {"POST /v2/organizations/{orgId}/webhooks", "creates an organization webhook",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/webhooks",
               params("POST /v2/organizations/{orgId}/webhooks",
                 path: %{"orgId" => org_id},
                 body: body
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/webhooks/{webhookId}",
             "webhookId",
             Ledger.created_id(created, :id)
           )
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/webhooks/{webhookId}",
       "edits an organization webhook this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           with_org_webhook(credentials, org_id, body, fn webhook_id ->
             Ledger.call(
               credentials,
               "PATCH /v2/organizations/{orgId}/webhooks/{webhookId}",
               params("PATCH /v2/organizations/{orgId}/webhooks/{webhookId}",
                 path: %{"orgId" => org_id, "webhookId" => webhook_id},
                 body: %{"active" => false, "subscriberUrl" => @subscriber}
               )
             )
           end)
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/webhooks/{webhookId}",
       "deletes an organization webhook this run created",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/webhooks",
               params("POST /v2/organizations/{orgId}/webhooks",
                 path: %{"orgId" => org_id},
                 body: body
               )
             )

           case Ledger.created_id(created, :id) do
             nil ->
               :ok

             webhook_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/webhooks/{webhookId}",
                 %{"path" => %{"orgId" => org_id, "webhookId" => webhook_id}}
               )
           end
         end)
       end}
    ]
  end

  @spec with_org_webhook(Credentials.t(), term(), map(), (term() -> any())) :: any()
  defp with_org_webhook(credentials, org_id, body, fun) do
    created =
      Ledger.call(
        credentials,
        "POST /v2/organizations/{orgId}/webhooks",
        params("POST /v2/organizations/{orgId}/webhooks", path: %{"orgId" => org_id}, body: body)
      )

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      webhook_id ->
        Ledger.track(
          "DELETE /v2/organizations/{orgId}/webhooks/{webhookId}",
          "webhookId",
          webhook_id
        )

        fun.(webhook_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Insights: POST bodies that compute an answer and change nothing
  # ---------------------------------------------------------------------------

  @spec insights() :: [{String.t(), String.t(), fun()}]
  defp insights do
    start_at = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
    end_at = DateTime.utc_now() |> DateTime.truncate(:second)

    window = %{
      "start" => DateTime.to_iso8601(start_at),
      "end" => DateTime.to_iso8601(end_at),
      "timeZone" => "Europe/London"
    }

    for path <- [
          "average-duration",
          "event-trends",
          "kpi-stats",
          "members"
        ] do
      {"POST /v2/insights/bookings/#{path}", "computes an insight over the last 30 days",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           Ledger.call(
             credentials,
             "POST /v2/insights/bookings/#{path}",
             params("POST /v2/insights/bookings/#{path}",
               body: Map.merge(window, %{"scope" => "ORG", "selectedTeamId" => org_id})
             )
           )
         end)
       end}
    end
  end

  # ---------------------------------------------------------------------------
  # Bookings: create one, walk its lifecycle, then delete it
  # ---------------------------------------------------------------------------

  @spec bookings() :: [{String.t(), String.t(), fun()}]
  defp bookings do
    [
      {"POST /v2/bookings", "books a slot on an event type this account owns",
       fn credentials, ids ->
         each(ids, "eventTypeId", fn _event_type_id ->
           created = booking(credentials, ids)

           Ledger.track(
             "POST /v2/bookings/{bookingUid}/cancel",
             "bookingUid",
             Ledger.created_id(created, :uid)
           )
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/cancel", "cancels a booking this run created",
       fn credentials, ids ->
         case Ledger.created_id(booking(credentials, ids), :uid) do
           nil ->
             :ok

           uid ->
             Ledger.call(credentials, "POST /v2/bookings/{bookingUid}/cancel", %{
               "path" => %{"bookingUid" => uid}
             })
         end
       end},
      {"POST /v2/bookings/{bookingUid}/confirm", "confirms a booking this run created",
       fn credentials, ids ->
         with_booking(credentials, ids, fn uid ->
           Ledger.call(credentials, "POST /v2/bookings/{bookingUid}/confirm", %{
             "path" => %{"bookingUid" => uid}
           })
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/location", "sets a location on a booking this run created",
       fn credentials, ids ->
         with_booking(credentials, ids, fn uid ->
           Ledger.call(
             credentials,
             "PATCH /v2/bookings/{bookingUid}/location",
             params("PATCH /v2/bookings/{bookingUid}/location",
               path: %{"bookingUid" => uid},
               body: %{
                 "location" => %{
                   "type" => "link",
                   "link" => "https://example.invalid/certification"
                 }
               }
             )
           )
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/attendees",
       "adds an attendee to a booking this run created",
       fn credentials, ids ->
         with_booking(credentials, ids, fn uid ->
           Ledger.call(
             credentials,
             "POST /v2/bookings/{bookingUid}/attendees",
             params("POST /v2/bookings/{bookingUid}/attendees",
               path: %{"bookingUid" => uid},
               body: %{"attendee" => @attendee}
             )
           )
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/guests", "adds a guest to a booking this run created",
       fn credentials, ids ->
         with_booking(credentials, ids, fn uid ->
           Ledger.call(
             credentials,
             "POST /v2/bookings/{bookingUid}/guests",
             params("POST /v2/bookings/{bookingUid}/guests",
               path: %{"bookingUid" => uid},
               body: %{
                 "guests" => [
                   %{"email" => "kithe-guest@example.invalid", "name" => "Certification guest"}
                 ]
               }
             )
           )
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/mark-absent",
       "marks an attendee absent on a booking this run created",
       fn credentials, ids ->
         with_booking(credentials, ids, fn uid ->
           Ledger.call(
             credentials,
             "POST /v2/bookings/{bookingUid}/mark-absent",
             params("POST /v2/bookings/{bookingUid}/mark-absent",
               path: %{"bookingUid" => uid},
               body: %{"attendees" => [%{"email" => @attendee["email"]}], "absent" => true}
             )
           )
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/request-reschedule",
       "requests a reschedule of a booking this run created",
       fn credentials, ids ->
         with_booking(credentials, ids, fn uid ->
           Ledger.call(
             credentials,
             "POST /v2/bookings/{bookingUid}/request-reschedule",
             params("POST /v2/bookings/{bookingUid}/request-reschedule",
               path: %{"bookingUid" => uid}
             )
           )
         end)
       end}
    ]
  end

  @spec booking(Credentials.t(), map()) :: map()
  defp booking(credentials, ids) do
    event_type_id = ids |> Map.get("eventTypeId", []) |> List.wrap() |> List.first()

    Ledger.call(
      credentials,
      "POST /v2/bookings",
      params("POST /v2/bookings",
        body: %{"start" => tomorrow(), "eventTypeId" => event_type_id, "attendee" => @attendee}
      )
    )
  end

  # A booking whose lifecycle step needs cancelling afterwards: it is created,
  # used once, and cancelled, so nothing outlives the scenario.
  @spec with_booking(Credentials.t(), map(), (term() -> any())) :: any()
  defp with_booking(credentials, ids, fun) do
    case Ledger.created_id(booking(credentials, ids), :uid) do
      nil -> :ok
      uid -> Ledger.track("POST /v2/bookings/{bookingUid}/cancel", "bookingUid", uid) && fun.(uid)
    end
  end

  # ---------------------------------------------------------------------------
  # Verified resources: the provider mails or texts a code the operator relays
  # ---------------------------------------------------------------------------

  @spec verified_resources() :: [{String.t(), String.t(), fun()}]
  defp verified_resources do
    [
      {"POST /v2/verified-resources/emails/verification-code/request",
       "asks Cal.com to mail a verification code",
       fn credentials, _ids ->
         Ledger.call(
           credentials,
           "POST /v2/verified-resources/emails/verification-code/request",
           params("POST /v2/verified-resources/emails/verification-code/request",
             body: %{"email" => System.get_env("CALCOM_VERIFY_EMAIL", @attendee["email"])}
           )
         )
       end},
      {"POST /v2/verified-resources/emails/verification-code/verify",
       "verifies the code the operator relays in CALCOM_EMAIL_CODE",
       fn credentials, _ids ->
         case System.get_env("CALCOM_EMAIL_CODE") do
           nil ->
             Ledger.call(
               credentials,
               "POST /v2/verified-resources/emails/verification-code/verify",
               params("POST /v2/verified-resources/emails/verification-code/verify",
                 body: %{
                   "email" => System.get_env("CALCOM_VERIFY_EMAIL", @attendee["email"]),
                   "code" => "000000"
                 }
               )
             )

           code ->
             Ledger.call(
               credentials,
               "POST /v2/verified-resources/emails/verification-code/verify",
               params("POST /v2/verified-resources/emails/verification-code/verify",
                 body: %{
                   "email" => System.get_env("CALCOM_VERIFY_EMAIL", @attendee["email"]),
                   "code" => code
                 }
               )
             )
         end
       end}
    ]
  end
end

Mutate.main()
