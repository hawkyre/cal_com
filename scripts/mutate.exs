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
Code.require_file("sweep/reap.exs", __DIR__)

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
  # A second attendee has to be someone else: Cal.com answers "Emails must be
  # unique and valid" when the addition repeats the booker.
  @second_attendee "kithe.certification.attendee@example.invalid"

  @doc "Print the plan, then run it when `MUTATE_APPLY=1`."
  @spec main() :: :ok
  def main do
    credentials = %Credentials{kind: :api_key, token: System.fetch_env!("CAL_COM_API_KEY")}
    scenarios = Enum.filter(scenarios(), &selected?/1)

    IO.puts("plan: #{length(scenarios)} scenarios, #{length(declined())} declined")

    for {id, proves, _fun} <- scenarios,
        do: Client.log("  #{String.pad_trailing(id, 74)} #{proves}")

    if System.get_env("MUTATE_APPLY") == "1" do
      # The read pass wipes this tree; the write pass has to do the same, or a
      # refusal's body from an earlier run outlives the verdict that replaced it.
      File.rm_rf!("test/support/fixtures/cal_com/unparsed")
      account = Discover.account(credentials)
      ids = Discover.ids(credentials, account)
      Client.log("account: user=#{account.user_id} org=#{inspect(account.organization_id)}")
      run(credentials, scenarios, ids)
      leftovers = Ledger.undo(credentials)
      if leftovers == [], do: Client.log("undo: everything this run created is gone")

      # The ledger cannot see a fixture whose create never parsed, so cleanup
      # finishes by finding anything still carrying the certification marker.
      reaped = Sweep.Reap.reap(true)
      Client.log("reap: #{reaped} fixtures removed by marker")
      finish(credentials, account)
    else
      IO.puts("\ndry run: set MUTATE_APPLY=1 to call these")
    end

    :ok
  end

  # A scenario that raises must not take its fixtures down with it: the caller
  # deletes everything tracked whatever happens here.
  @spec run(Credentials.t(), [{String.t(), String.t(), fun()}], map()) :: :ok
  defp run(credentials, scenarios, ids) do
    for {id, _proves, fun} <- scenarios do
      try do
        fun.(credentials, ids)
      rescue
        error ->
          Client.log("  SCENARIO RAISED #{id}: #{Exception.message(error)}")

          Client.log(
            "    " <>
              Enum.map_join(
                Enum.take(__STACKTRACE__, 4),
                "\n    ",
                &Exception.format_stacktrace_entry/1
              )
          )
      catch
        kind, reason ->
          Client.log("  SCENARIO EXITED #{id}: #{inspect({kind, reason})}")
      end
    end

    :ok
  end

  # `MUTATE_ONLY` runs every scenario whose operation id contains one of the
  # comma separated fragments (`bookings`, `verified`, a whole id); `MUTATE_SKIP`
  # leaves them out. Both keep a staged run honest: what was skipped stays a
  # recorded `write`, not a silent success.
  @spec selected?({String.t(), String.t(), fun()}) :: boolean()
  defp selected?({id, _proves, _fun}) do
    only = fragments("MUTATE_ONLY")
    skip = fragments("MUTATE_SKIP")

    (only == [] or Enum.any?(only, &String.contains?(id, &1))) and
      not Enum.any?(skip, &String.contains?(id, &1))
  end

  @spec fragments(String.t()) :: [String.t()]
  defp fragments(variable) do
    case System.get_env(variable) do
      nil -> []
      value -> value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  @spec finish(Credentials.t(), map()) :: :ok
  defp finish(_credentials, _account) do
    # Captures are written exactly as the read pass writes them: a body the
    # contract refused is evidence for a fix, not a parsed response. The capture
    # itself cannot go into the report — it holds live structs and a response.
    for {id, verdict} <- Ledger.verdicts(), do: write_capture(id, verdict)

    Ledger.verdicts()
    |> Map.new(fn {id, verdict} ->
      # `fields` names each offending path as a tuple, which JSON cannot encode;
      # the read pass writes the same pairs as objects.
      fields =
        for {path, why} <- Map.get(verdict, :fields, []), do: %{"path" => path, "why" => why}

      {id, verdict |> Map.delete(:capture) |> Map.put(:fields, fields)}
    end)
    |> Map.merge(
      Map.new(declined(), fn {id, reason} -> {id, %{status: "declined", reason: reason}} end)
    )
    |> merge_into_report()

    :ok
  end

  @spec write_capture(String.t(), map()) :: :ok
  defp write_capture(id, verdict) do
    case verdict[:capture] do
      {false, package} -> Report.capture!(id, package, parsed: false)
      {nil, package} -> Report.capture!(id, package, parsed: false)
      {%{} = _typed, package} -> Report.capture!(id, package, parsed: true)
      _none -> :ok
    end
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
      {"POST /v2/calendars/{calendar}/disconnect", "needs a connected third-party calendar"},
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
      {"DELETE /v2/teams/{teamId}/memberships/{membershipId}",
       "the account holds one membership per team and the provider refuses a second with 409, so the only membership this could delete is the user's own"},
      {"POST /v2/teams/{teamId}/memberships", "the user route answers 403 for this account"},
      {"POST /v2/event-types/{eventTypeId}/booking-fields",
       "no input can succeed: `field` must be one of ten system names on every write route, and a system field is refused with \"Only custom booking fields can be added\""},
      {"POST /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "no input can succeed: `field` must be one of ten system names on every write route, and a system field is refused with \"Only custom booking fields can be added\""},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "no input can succeed: `field` must be one of ten system names on every write route, and a system field is refused with \"Only custom booking fields can be added\""},
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
      event_type_children() ++
      team_scoped() ++
      team_booking_fields() ++
      booking_field_deletes() ++
      team_admin() ++
      org_users() ++
      memberships() ++
      attributes_with_options() ++
      attribute_options() ++
      account_settings() ++
      insights() ++
      bookings() ++
      verified_resources()
  end

  # ---------------------------------------------------------------------------
  # Input helpers
  # ---------------------------------------------------------------------------

  # The input parts an operation declares, with the scenario's values laid over
  # the required fields sampled from its own contract. A part the operation does
  # not declare is never sent — its input contract rejects an undeclared part —
  # and an optional part nobody filled in is left out rather than sent empty.
  @spec params(String.t(), keyword()) :: map()
  defp params(operation_id, options) do
    operation = CalCom.Registry.find(operation_id)

    %{}
    |> put(operation, "path", Keyword.get(options, :path))
    |> put(operation, "query", merge_part(operation, "query", Keyword.get(options, :query, %{})))
    |> put(operation, "body", merge_part(operation, "body", Keyword.get(options, :body, %{})))
  end

  @spec put(map(), CalCom.Operation.t(), String.t(), map() | nil) :: map()
  defp put(params, operation, part, values) do
    case Enum.find(operation.input_module.fields(), &(&1.wire == part)) do
      nil -> params
      %{required: true} -> Map.put(params, part, values || %{})
      %{required: false} when values in [nil, %{}] -> params
      %{required: false} -> Map.put(params, part, values)
    end
  end

  @spec merge_part(CalCom.Operation.t(), String.t(), map()) :: map()
  defp merge_part(operation, part, overrides) do
    base =
      case Enum.find(operation.input_module.fields(), &(&1.wire == part)) do
        %{rule: %{kind: {:object, module}}} -> Inputs.required_fields(module)
        %{rule: %{kind: {:one_of, [rule | _rest]}}} -> Inputs.sample(rule)
        _none -> %{}
      end

    # A union whose first variant samples to a scalar leaves nothing to merge
    # into; the scenario's own values then stand alone and the provider decides.
    if is_map(base), do: Map.merge(base, overrides), else: overrides
  end

  # A unique slug/name per call, so two scenarios never collide on the same
  # resource: the provider answers a duplicate slug with 409, which would look
  # like a contract failure instead of a fixture collision.
  @spec suffix() :: String.t()
  defp suffix do
    counter = Process.get(:certify_suffix, 0) + 1
    Process.put(:certify_suffix, counter)
    Integer.to_string(System.system_time(:second), 36) <> Integer.to_string(counter, 36)
  end

  # A webhook destination nothing listens on, unique per call for the same reason.
  @spec subscriber() :: String.t()
  defp subscriber, do: @subscriber <> "-" <> suffix()

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
                 "subscriberUrl" => subscriber(),
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
               body: %{"active" => false}
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
                 "subscriberUrl" => subscriber(),
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
           # The field body is a tagged union; the contract samples it, a guess
           # does not.
           Ledger.call(
             credentials,
             "POST /v2/event-types/{eventTypeId}/booking-fields",
             params("POST /v2/event-types/{eventTypeId}/booking-fields",
               path: %{"eventTypeId" => id},
               body: %{
                 "bookingFields" => [
                   %{
                     "field" => "text",
                     "slug" => slug("cert-field"),
                     "label" => "Certification field",
                     "required" => false
                   }
                 ]
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
       fn credentials, _ids ->
         Ledger.track(
           "DELETE /v2/slots/reservations/{uid}",
           "uid",
           Ledger.created_id(reservation(credentials), :reservation_uid)
         )
       end},
      {"PATCH /v2/slots/reservations/{uid}", "edits the reservation this run created",
       fn credentials, _ids ->
         with_reservation(credentials, fn uid ->
           Ledger.call(
             credentials,
             "PATCH /v2/slots/reservations/{uid}",
             params("PATCH /v2/slots/reservations/{uid}", path: %{"uid" => uid}, body: %{})
           )
         end)
       end},
      {"DELETE /v2/slots/reservations/{uid}", "releases a reservation this run created",
       fn credentials, _ids ->
         case Ledger.created_id(reservation(credentials), :reservation_uid) do
           nil ->
             :ok

           uid ->
             Ledger.call(credentials, "DELETE /v2/slots/reservations/{uid}", %{
               "path" => %{"uid" => uid}
             })
         end
       end}
    ]
  end

  # A reservation takes a slot the provider reports as open on an event type this
  # run is willing to lose, so it borrows the same fixture the bookings use.
  @spec reservation(Credentials.t()) :: map()
  defp reservation(credentials) do
    case free_slot(credentials) do
      nil ->
        Ledger.call(credentials, "POST /v2/slots/reservations", %{"body" => %{}})

      {event_type_id, start} ->
        Ledger.call(
          credentials,
          "POST /v2/slots/reservations",
          params("POST /v2/slots/reservations",
            body: %{"eventTypeId" => event_type_id, "slotStart" => start}
          )
        )
    end
  end

  @spec with_reservation(Credentials.t(), (term() -> any())) :: any()
  defp with_reservation(credentials, fun) do
    case Ledger.created_id(reservation(credentials), :reservation_uid) do
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
                 "start" => ooo_window()["start"],
                 "end" => ooo_window()["end"]
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
        body: Map.merge(ooo_window(), %{"notes" => "cal_com certification"})
      )
    )
  end

  # Out-of-office entries for the same day overlap, and the provider answers an
  # overlap with 409, so each scenario takes its own day.
  @spec ooo_window() :: map()
  defp ooo_window do
    day = Process.get(:certify_ooo_day, 0) + 1
    Process.put(:certify_ooo_day, day)
    start_at = DateTime.utc_now() |> DateTime.add(day, :day) |> DateTime.truncate(:second)

    %{
      "start" => DateTime.to_iso8601(start_at),
      "end" => DateTime.to_iso8601(DateTime.add(start_at, 8, :hour))
    }
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
    # The workflow body comes from the operation's own contract: a workflow step
    # is a tagged union the generator already knows how to sample, and a
    # hand-written guess at it is exactly what failed before the first call.
    body = fn overrides ->
      base = merge_part(CalCom.Registry.find("POST /v2/workflows"), "body", %{})
      Map.merge(base, Map.merge(%{"name" => "Kithe certification " <> suffix()}, overrides))
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
      {"POST /v2/organizations/{orgId}/teams/{teamId}/roles", "creates a team role",
       fn credentials, ids ->
         each(ids, "orgId", fn org_id ->
           with_team(credentials, fn team_id ->
             created =
               Ledger.call(
                 credentials,
                 "POST /v2/organizations/{orgId}/teams/{teamId}/roles",
                 params("POST /v2/organizations/{orgId}/teams/{teamId}/roles",
                   path: %{"orgId" => org_id, "teamId" => team_id},
                   body: %{
                     "name" => "Kithe cert role " <> suffix(),
                     "permissions" => ["booking.read"]
                   }
                 )
               )

             Ledger.track("DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}", %{
               "orgId" => org_id,
               "teamId" => team_id,
               "roleId" => Ledger.created_id(created, :id)
             })
           end)
         end)
       end}
    ]
  end

  # `POST /v2/teams` is payment-gated on this plan: it answers 201 with a
  # `pendingTeam` and a Stripe payment link, and the team exists only once the
  # payment completes. Nothing is created, so nothing is tracked for cleanup.
  # The team-scoped scenarios therefore address a team the account already has.
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
             %{"orgId" => org_id, "attributeId" => Ledger.created_id(created, :id)}
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
          %{"orgId" => org_id, "attributeId" => attribute_id}
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
             %{"orgId" => org_id, "roleId" => Ledger.created_id(created, :id)}
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
        Ledger.track("DELETE /v2/organizations/{orgId}/roles/{roleId}", %{
          "orgId" => org_id,
          "roleId" => role_id
        })

        fun.(role_id)
    end
  end

  @spec organization_webhooks() :: [{String.t(), String.t(), fun()}]
  defp organization_webhooks do
    body = fn ->
      %{"active" => true, "subscriberUrl" => subscriber(), "triggers" => ["BOOKING_CREATED"]}
    end

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
                 body: body.()
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/webhooks/{webhookId}",
             %{"orgId" => org_id, "webhookId" => Ledger.created_id(created, :id)}
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
                 body: %{"active" => false}
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
                 body: body.()
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
        params("POST /v2/organizations/{orgId}/webhooks",
          path: %{"orgId" => org_id},
          body: body.()
        )
      )

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      webhook_id ->
        Ledger.track(
          "DELETE /v2/organizations/{orgId}/webhooks/{webhookId}",
          %{"orgId" => org_id, "webhookId" => webhook_id}
        )

        fun.(webhook_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Team-scoped resources, built under an event type on a team the account owns
  # ---------------------------------------------------------------------------

  # `POST /v2/teams` is payment-gated, so the fixture parent is a team the
  # account already owns. Only children are created, and every one is deleted.
  @spec team_fixture(Credentials.t()) :: term()
  defp team_fixture(credentials) do
    case Process.get(:certify_team_fixture) do
      nil ->
        id =
          case Ledger.call(credentials, "GET /v2/teams", %{})[:capture] do
            {%{} = typed, _package} ->
              # The organization itself is listed first and answers 403 for a
              # child event type, so it is excluded by its own id.
              typed.value.data
              |> List.wrap()
              |> Enum.map(&Map.get(&1, :id))
              |> Enum.reject(&(&1 == organization_id(credentials)))
              |> List.first()

            _none ->
              nil
          end

        Process.put(:certify_team_fixture, id)
        id

      id ->
        id
    end
  end

  @spec organization_id(Credentials.t()) :: term()
  defp organization_id(credentials) do
    case Client.call(credentials, "GET /v2/me", %{}) do
      {:ok, me} -> me.value.data.organization_id
      _error -> nil
    end
  end

  @spec team_user_id(Credentials.t()) :: term()
  defp team_user_id(credentials) do
    case Process.get(:certify_user_id) do
      nil ->
        {:ok, me} = Client.call(credentials, "GET /v2/me", %{})
        id = me.value.data.id
        Process.put(:certify_user_id, id)
        id

      id ->
        id
    end
  end

  # A team event type needs a scheduling type; without one the provider answers
  # 400 and lists ROUND_ROBIN, COLLECTIVE and MANAGED.
  @spec team_event_type(Credentials.t(), term()) :: map()
  defp team_event_type(credentials, team_id) do
    Ledger.call(
      credentials,
      "POST /v2/teams/{teamId}/event-types",
      params("POST /v2/teams/{teamId}/event-types",
        path: %{"teamId" => team_id},
        body: %{
          "title" => "Kithe certification team event",
          "slug" => slug("kithe-team-cert"),
          "lengthInMinutes" => 15,
          "schedulingType" => "collective",
          "hosts" => [%{"userId" => team_user_id(credentials), "isFixed" => true}]
        }
      )
    )
  end

  @spec with_team_event_type(Credentials.t(), (term(), term() -> any())) :: any()
  defp with_team_event_type(credentials, fun) do
    case team_fixture(credentials) do
      nil ->
        :ok

      team_id ->
        case Ledger.created_id(team_event_type(credentials, team_id), :id) do
          nil ->
            :ok

          event_type_id ->
            Ledger.track("DELETE /v2/teams/{teamId}/event-types/{eventTypeId}", %{
              "teamId" => team_id,
              "eventTypeId" => event_type_id
            })

            fun.(team_id, event_type_id)
        end
    end
  end

  @spec team_path(term(), term()) :: map()
  defp team_path(team_id, event_type_id),
    do: %{"teamId" => team_id, "eventTypeId" => event_type_id}

  @spec team_webhook(Credentials.t(), map()) :: map()
  defp team_webhook(credentials, path) do
    Ledger.call(
      credentials,
      "POST /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks",
      params("POST /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks",
        path: path,
        body: %{
          "active" => true,
          "subscriberUrl" => subscriber(),
          "triggers" => ["BOOKING_CREATED"]
        }
      )
    )
  end

  @spec team_scoped() :: [{String.t(), String.t(), fun()}]
  defp team_scoped do
    [
      {"POST /v2/teams/{teamId}/event-types",
       "creates a team event type on a team this account owns",
       fn credentials, _ids -> with_team_event_type(credentials, fn _team, _event -> :ok end) end},
      {"PATCH /v2/teams/{teamId}/event-types/{eventTypeId}",
       "edits the team event type this run created",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/teams/{teamId}/event-types/{eventTypeId}",
             params("PATCH /v2/teams/{teamId}/event-types/{eventTypeId}",
               path: team_path(team_id, event_type_id),
               body: %{"title" => "Kithe certification team event (edited)"}
             )
           )
         end)
       end},
      {"DELETE /v2/teams/{teamId}/event-types/{eventTypeId}",
       "deletes a team event type this run created",
       fn credentials, _ids ->
         case team_fixture(credentials) do
           nil ->
             :ok

           team_id ->
             case Ledger.created_id(team_event_type(credentials, team_id), :id) do
               nil ->
                 :ok

               event_type_id ->
                 Ledger.call(
                   credentials,
                   "DELETE /v2/teams/{teamId}/event-types/{eventTypeId}",
                   %{"path" => team_path(team_id, event_type_id)}
                 )
             end
         end
       end},
      {"POST /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks",
       "adds a webhook to a team event type this run created",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           path = team_path(team_id, event_type_id)
           created = team_webhook(credentials, path)

           Ledger.track(
             "DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks/{webhookId}",
             Map.put(path, "webhookId", Ledger.created_id(created, :id))
           )
         end)
       end},
      {"PATCH /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks/{webhookId}",
       "edits a webhook this run created on a team event type",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           path = team_path(team_id, event_type_id)

           case Ledger.created_id(team_webhook(credentials, path), :id) do
             nil ->
               :ok

             webhook_id ->
               Ledger.call(
                 credentials,
                 "PATCH /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks/{webhookId}",
                 params("PATCH /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks/{webhookId}",
                   path: Map.put(path, "webhookId", webhook_id),
                   body: %{"active" => false}
                 )
               )
           end
         end)
       end},
      {"DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks/{webhookId}",
       "deletes a webhook this run created on a team event type",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           path = team_path(team_id, event_type_id)

           case Ledger.created_id(team_webhook(credentials, path), :id) do
             nil ->
               :ok

             webhook_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks/{webhookId}",
                 %{"path" => Map.put(path, "webhookId", webhook_id)}
               )
           end
         end)
       end},
      {"DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks",
       "deletes every webhook of a team event type this run created",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           path = team_path(team_id, event_type_id)
           team_webhook(credentials, path)

           Ledger.call(
             credentials,
             "DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks",
             params("DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/webhooks", path: path)
           )
         end)
       end}
    ]
  end

  # ---------------------------------------------------------------------------
  # Memberships and attribute assignments
  # ---------------------------------------------------------------------------
  #
  # Two rules keep these safe. A PATCH sends the role the membership already has,
  # so it proves the call without changing anyone's access; a DELETE only ever
  # targets a membership this run created itself.

  @spec membership_row(Credentials.t(), String.t(), map()) :: map() | nil
  defp membership_row(credentials, list_id, params) do
    case Ledger.call(credentials, list_id, params)[:capture] do
      {%{} = typed, _package} -> typed.value.data |> List.wrap() |> List.first()
      _none -> nil
    end
  end

  # A parsed enum field arrives as an atom, and the request contract wants the
  # wire string back, so the value is converted rather than passed through.
  @spec membership_role(map() | nil) :: String.t()
  defp membership_role(nil), do: "MEMBER"
  defp membership_role(row), do: row |> Map.get(:role) |> role_wire()

  @spec role_wire(term()) :: String.t()
  defp role_wire(nil), do: "MEMBER"
  defp role_wire(role) when is_atom(role), do: Atom.to_string(role)
  defp role_wire(role), do: to_string(role)

  @spec add_team_membership(Credentials.t(), map()) :: map()
  defp add_team_membership(credentials, path) do
    Ledger.call(
      credentials,
      "POST /v2/organizations/{orgId}/teams/{teamId}/memberships",
      params("POST /v2/organizations/{orgId}/teams/{teamId}/memberships",
        path: path,
        body: %{"userId" => team_user_id(credentials), "role" => "MEMBER", "accepted" => true}
      )
    )
  end

  # A membership created here owns nothing, so deleting it removes only what this
  # run added.
  @spec with_added_membership(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_added_membership(credentials, fun) do
    with_team_admin(credentials, fn org_id, team_id ->
      path = team_admin_path(org_id, team_id)

      case Ledger.created_id(add_team_membership(credentials, path), :id) do
        nil ->
          :ok

        membership_id ->
          Ledger.track(
            "DELETE /v2/organizations/{orgId}/teams/{teamId}/memberships/{membershipId}",
            Map.put(path, "membershipId", membership_id)
          )

          fun.(path, membership_id)
      end
    end)
  end

  @spec membership_path(term(), term(), term()) :: map()
  defp membership_path(org_id, team_id, membership_id) do
    %{"orgId" => org_id, "teamId" => team_id, "membershipId" => membership_id}
  end

  @spec attributes_with_options() :: [{String.t(), String.t(), fun()}]
  defp attributes_with_options do
    body = fn ->
      option = %{"value" => "certification", "slug" => slug("cert-option")}

      %{
        "name" => "Kithe certification " <> suffix(),
        "slug" => slug("kithe-cert"),
        "type" => "SINGLE_SELECT",
        "options" => [option],
        "enabled" => true
      }
    end

    [
      {"POST /v2/organizations/{orgId}/attributes/options/{userId}",
       "assigns an attribute option to this user",
       fn credentials, _ids ->
         with_org_id(credentials, fn org_id ->
           case with_attribute_assignment(credentials, org_id, body, fn _attribute, _option ->
                  :ok
                end) do
             :ok -> :ok
           end
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/attributes/options/{userId}/{attributeOptionId}",
       "edits the attribute assignment this run made",
       fn credentials, _ids ->
         with_org_id(credentials, fn org_id ->
           with_attribute_assignment(credentials, org_id, body, fn attribute_id, option_id ->
             Ledger.call(
               credentials,
               "PATCH /v2/organizations/{orgId}/attributes/options/{userId}/{attributeOptionId}",
               params(
                 "PATCH /v2/organizations/{orgId}/attributes/options/{userId}/{attributeOptionId}",
                 path: %{
                   "orgId" => org_id,
                   "userId" => team_user_id(credentials),
                   "attributeOptionId" => option_id
                 },
                 body: %{"weight" => 1}
               )
             )

             _ = attribute_id
           end)
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/attributes/options/{userId}/{attributeOptionId}",
       "removes the attribute assignment this run made",
       fn credentials, _ids ->
         with_org_id(credentials, fn org_id ->
           with_attribute_assignment(credentials, org_id, body, fn _attribute_id, option_id ->
             Ledger.call(
               credentials,
               "DELETE /v2/organizations/{orgId}/attributes/options/{userId}/{attributeOptionId}",
               %{
                 "path" => %{
                   "orgId" => org_id,
                   "userId" => team_user_id(credentials),
                   "attributeOptionId" => option_id
                 }
               }
             )
           end)
         end)
       end}
    ]
  end

  # Creates an attribute with one option, assigns it to this user, and hands the
  # attribute and option ids to the scenario; the attribute is deleted afterwards,
  # which removes the assignment and the option with it.
  @spec with_attribute_assignment(Credentials.t(), term(), (-> map()), (term(), term() -> any())) ::
          any()
  defp with_attribute_assignment(credentials, org_id, body, fun) do
    created =
      Ledger.call(
        credentials,
        "POST /v2/organizations/{orgId}/attributes",
        params("POST /v2/organizations/{orgId}/attributes",
          path: %{"orgId" => org_id},
          body: body.()
        )
      )

    case Ledger.created_id(created, :id) do
      nil ->
        :ok

      attribute_id ->
        Ledger.track("DELETE /v2/organizations/{orgId}/attributes/{attributeId}", %{
          "orgId" => org_id,
          "attributeId" => attribute_id
        })

        option_id = attribute_option_id(credentials, org_id, attribute_id)

        if is_nil(option_id) do
          :ok
        else
          Ledger.call(
            credentials,
            "POST /v2/organizations/{orgId}/attributes/options/{userId}",
            params("POST /v2/organizations/{orgId}/attributes/options/{userId}",
              path: %{"orgId" => org_id, "userId" => team_user_id(credentials)},
              body: %{"attributeId" => attribute_id, "attributeOptionId" => option_id}
            )
          )

          fun.(attribute_id, option_id)
        end
    end
  end

  @spec attribute_option_id(Credentials.t(), term(), term()) :: term()
  defp attribute_option_id(credentials, org_id, attribute_id) do
    params = %{"path" => %{"orgId" => org_id, "attributeId" => attribute_id}}

    case Ledger.call(
           credentials,
           "GET /v2/organizations/{orgId}/attributes/{attributeId}/options",
           params
         )[:capture] do
      {%{} = typed, _package} ->
        typed.value.data |> List.wrap() |> List.first() |> then(&(&1 && Map.get(&1, :id)))

      _none ->
        nil
    end
  end

  @spec memberships() :: [{String.t(), String.t(), fun()}]
  defp memberships do
    [
      {"POST /v2/organizations/{orgId}/teams/{teamId}/memberships",
       "adds this user to a team through the organization route",
       fn credentials, _ids -> with_added_membership(credentials, fn _path, _id -> :ok end) end},
      {"PATCH /v2/organizations/{orgId}/teams/{teamId}/memberships/{membershipId}",
       "edits this user's team membership, sending the role it already has",
       fn credentials, _ids ->
         with_team_admin(credentials, fn org_id, team_id ->
           path = team_admin_path(org_id, team_id)

           row =
             membership_row(
               credentials,
               "GET /v2/organizations/{orgId}/teams/{teamId}/memberships",
               params("GET /v2/organizations/{orgId}/teams/{teamId}/memberships", path: path)
             )

           case row && Map.get(row, :id) do
             nil ->
               :ok

             membership_id ->
               Ledger.call(
                 credentials,
                 "PATCH /v2/organizations/{orgId}/teams/{teamId}/memberships/{membershipId}",
                 params(
                   "PATCH /v2/organizations/{orgId}/teams/{teamId}/memberships/{membershipId}",
                   path: membership_path(org_id, team_id, membership_id),
                   body: %{"role" => membership_role(row), "disableImpersonation" => false}
                 )
               )
           end
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/teams/{teamId}/memberships/{membershipId}",
       "removes a team membership this run added",
       fn credentials, _ids ->
         with_team_admin(credentials, fn org_id, team_id ->
           path = team_admin_path(org_id, team_id)

           case Ledger.created_id(add_team_membership(credentials, path), :id) do
             nil ->
               :ok

             membership_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/teams/{teamId}/memberships/{membershipId}",
                 %{"path" => membership_path(org_id, team_id, membership_id)}
               )
           end
         end)
       end},
      {"PATCH /v2/teams/{teamId}/memberships/{membershipId}",
       "edits this user's team membership through the user route, sending its current role",
       fn credentials, _ids ->
         with_team_user(credentials, fn _path, team_id ->
           row =
             membership_row(credentials, "GET /v2/teams/{teamId}/memberships", %{
               "path" => %{"teamId" => team_id}
             })

           case row && Map.get(row, :id) do
             nil ->
               :ok

             membership_id ->
               Ledger.call(
                 credentials,
                 "PATCH /v2/teams/{teamId}/memberships/{membershipId}",
                 params("PATCH /v2/teams/{teamId}/memberships/{membershipId}",
                   path: %{"teamId" => team_id, "membershipId" => membership_id},
                   body: %{"role" => membership_role(row), "disableImpersonation" => false}
                 )
               )
           end
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/memberships/{membershipId}",
       "edits this user's organization membership, sending the role it already has",
       fn credentials, _ids ->
         with_org_id(credentials, fn org_id ->
           row =
             membership_row(
               credentials,
               "GET /v2/organizations/{orgId}/memberships",
               params("GET /v2/organizations/{orgId}/memberships", path: %{"orgId" => org_id})
             )

           case row && Map.get(row, :id) do
             nil ->
               :ok

             membership_id ->
               Ledger.call(
                 credentials,
                 "PATCH /v2/organizations/{orgId}/memberships/{membershipId}",
                 params("PATCH /v2/organizations/{orgId}/memberships/{membershipId}",
                   path: %{"orgId" => org_id, "membershipId" => membership_id},
                   body: %{"role" => membership_role(row), "disableImpersonation" => false}
                 )
               )
           end
         end)
       end}
    ]
  end

  @spec with_new_attribute(Credentials.t(), (-> map()), (term(), term() -> any())) :: any()
  defp with_new_attribute(credentials, body, fun) do
    with_org_id(credentials, fn org_id ->
      created =
        Ledger.call(
          credentials,
          "POST /v2/organizations/{orgId}/attributes",
          params("POST /v2/organizations/{orgId}/attributes",
            path: %{"orgId" => org_id},
            body: body.()
          )
        )

      case Ledger.created_id(created, :id) do
        nil ->
          :ok

        attribute_id ->
          Ledger.track("DELETE /v2/organizations/{orgId}/attributes/{attributeId}", %{
            "orgId" => org_id,
            "attributeId" => attribute_id
          })

          fun.(org_id, attribute_id)
      end
    end)
  end

  @spec attribute_option_body() :: map()
  defp attribute_option_body, do: %{"value" => "certification", "slug" => slug("cert-option")}

  @spec add_attribute_option(Credentials.t(), term(), term()) :: map()
  defp add_attribute_option(credentials, org_id, attribute_id) do
    Ledger.call(
      credentials,
      "POST /v2/organizations/{orgId}/attributes/{attributeId}/options",
      params("POST /v2/organizations/{orgId}/attributes/{attributeId}/options",
        path: %{"orgId" => org_id, "attributeId" => attribute_id},
        body: attribute_option_body()
      )
    )
  end

  @spec attribute_options() :: [{String.t(), String.t(), fun()}]
  defp attribute_options do
    body = fn ->
      %{
        "name" => "Kithe certification " <> suffix(),
        "slug" => slug("kithe-cert"),
        "type" => "TEXT",
        "options" => [],
        "enabled" => true
      }
    end

    [
      {"POST /v2/organizations/{orgId}/attributes/{attributeId}/options",
       "adds an option to an attribute this run created",
       fn credentials, _ids ->
         with_new_attribute(credentials, body, fn org_id, attribute_id ->
           add_attribute_option(credentials, org_id, attribute_id)
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/attributes/{attributeId}/options/{optionId}",
       "edits the attribute option this run created",
       fn credentials, _ids ->
         with_new_attribute(credentials, body, fn org_id, attribute_id ->
           case Ledger.created_id(add_attribute_option(credentials, org_id, attribute_id), :id) do
             nil ->
               :ok

             option_id ->
               Ledger.call(
                 credentials,
                 "PATCH /v2/organizations/{orgId}/attributes/{attributeId}/options/{optionId}",
                 params(
                   "PATCH /v2/organizations/{orgId}/attributes/{attributeId}/options/{optionId}",
                   path: %{
                     "orgId" => org_id,
                     "attributeId" => attribute_id,
                     "optionId" => option_id
                   },
                   body: %{"value" => "certification edited", "slug" => slug("cert-option")}
                 )
               )
           end
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/attributes/{attributeId}/options/{optionId}",
       "deletes an attribute option this run created",
       fn credentials, _ids ->
         with_new_attribute(credentials, body, fn org_id, attribute_id ->
           case Ledger.created_id(add_attribute_option(credentials, org_id, attribute_id), :id) do
             nil ->
               :ok

             option_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/attributes/{attributeId}/options/{optionId}",
                 %{
                   "path" => %{
                     "orgId" => org_id,
                     "attributeId" => attribute_id,
                     "optionId" => option_id
                   }
                 }
               )
           end
         end)
       end}
    ]
  end

  # ---------------------------------------------------------------------------
  # The account's own user, addressed through the organization routes
  # ---------------------------------------------------------------------------

  @spec org_user_path(term(), term()) :: map()
  defp org_user_path(org_id, user_id), do: %{"orgId" => org_id, "userId" => user_id}

  @spec with_org_user(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_org_user(credentials, fun) do
    with_org_id(credentials, fn org_id ->
      fun.(org_user_path(org_id, team_user_id(credentials)), org_id)
    end)
  end

  @spec org_ooo(Credentials.t(), map()) :: map()
  defp org_ooo(credentials, path) do
    Ledger.call(
      credentials,
      "POST /v2/organizations/{orgId}/users/{userId}/ooo",
      params("POST /v2/organizations/{orgId}/users/{userId}/ooo",
        path: path,
        body: Map.merge(ooo_window(), %{"notes" => "cal_com certification"})
      )
    )
  end

  @spec with_org_ooo(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_org_ooo(credentials, fun) do
    with_org_user(credentials, fn path, _org_id ->
      case Ledger.created_id(org_ooo(credentials, path), :id) do
        nil ->
          :ok

        ooo_id ->
          Ledger.track(
            "DELETE /v2/organizations/{orgId}/users/{userId}/ooo/{oooId}",
            Map.put(path, "oooId", ooo_id)
          )

          fun.(path, ooo_id)
      end
    end)
  end

  @spec org_schedule(Credentials.t(), map()) :: map()
  defp org_schedule(credentials, path) do
    Ledger.call(
      credentials,
      "POST /v2/organizations/{orgId}/users/{userId}/schedules",
      params("POST /v2/organizations/{orgId}/users/{userId}/schedules",
        path: path,
        body: %{
          "name" => "Kithe certification " <> suffix(),
          "timeZone" => "Europe/London",
          "isDefault" => false
        }
      )
    )
  end

  @spec with_org_schedule(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_org_schedule(credentials, fun) do
    with_org_user(credentials, fn path, _org_id ->
      case Ledger.created_id(org_schedule(credentials, path), :id) do
        nil ->
          :ok

        schedule_id ->
          Ledger.track(
            "DELETE /v2/organizations/{orgId}/users/{userId}/schedules/{scheduleId}",
            Map.put(path, "scheduleId", schedule_id)
          )

          fun.(path, schedule_id)
      end
    end)
  end

  @spec org_users() :: [{String.t(), String.t(), fun()}]
  defp org_users do
    [
      {"PATCH /v2/organizations/{orgId}/users/{userId}",
       "edits this user through the organization route, then puts the name back",
       fn credentials, _ids ->
         with_org_user(credentials, fn path, _org_id ->
           # The organization route has no single-user GET, so the current name
           # comes from /v2/me and the PATCH sends that same value: the profile is
           # left exactly as it was found.
           {:ok, me} = Client.call(credentials, "GET /v2/me", %{})

           Ledger.call(
             credentials,
             "PATCH /v2/organizations/{orgId}/users/{userId}",
             params("PATCH /v2/organizations/{orgId}/users/{userId}",
               path: path,
               body: %{"name" => me.value.data.name}
             )
           )
         end)
       end},
      {"POST /v2/organizations/{orgId}/users/{userId}/ooo",
       "records an out-of-office entry through the organization route",
       fn credentials, _ids ->
         with_org_ooo(credentials, fn _path, _ooo -> :ok end)
       end},
      {"PATCH /v2/organizations/{orgId}/users/{userId}/ooo/{oooId}",
       "edits the out-of-office entry this run created",
       fn credentials, _ids ->
         with_org_ooo(credentials, fn path, ooo_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/organizations/{orgId}/users/{userId}/ooo/{oooId}",
             params("PATCH /v2/organizations/{orgId}/users/{userId}/ooo/{oooId}",
               path: Map.put(path, "oooId", ooo_id),
               body: Map.merge(ooo_window(), %{"notes" => "Edited by the certification sweep"})
             )
           )
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/users/{userId}/ooo/{oooId}",
       "deletes an out-of-office entry this run created",
       fn credentials, _ids ->
         with_org_user(credentials, fn path, _org_id ->
           case Ledger.created_id(org_ooo(credentials, path), :id) do
             nil ->
               :ok

             ooo_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/users/{userId}/ooo/{oooId}",
                 %{"path" => Map.put(path, "oooId", ooo_id)}
               )
           end
         end)
       end},
      {"POST /v2/organizations/{orgId}/users/{userId}/schedules",
       "creates a schedule through the organization route",
       fn credentials, _ids ->
         with_org_schedule(credentials, fn _path, _schedule -> :ok end)
       end},
      {"PATCH /v2/organizations/{orgId}/users/{userId}/schedules/{scheduleId}",
       "edits the schedule this run created",
       fn credentials, _ids ->
         with_org_schedule(credentials, fn path, schedule_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/organizations/{orgId}/users/{userId}/schedules/{scheduleId}",
             params("PATCH /v2/organizations/{orgId}/users/{userId}/schedules/{scheduleId}",
               path: Map.put(path, "scheduleId", schedule_id),
               body: %{"name" => "Kithe certification (edited) " <> suffix()}
             )
           )
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/users/{userId}/schedules/{scheduleId}",
       "deletes a schedule this run created",
       fn credentials, _ids ->
         with_org_user(credentials, fn path, _org_id ->
           case Ledger.created_id(org_schedule(credentials, path), :id) do
             nil ->
               :ok

             schedule_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/users/{userId}/schedules/{scheduleId}",
                 %{"path" => Map.put(path, "scheduleId", schedule_id)}
               )
           end
         end)
       end},
      {"POST /v2/organizations/{orgId}/users/{userId}/conferencing/default",
       "sets a default conferencing app for this user",
       fn credentials, _ids ->
         with_org_user(credentials, fn path, _org_id ->
           Ledger.call(
             credentials,
             "POST /v2/organizations/{orgId}/users/{userId}/conferencing/default",
             params("POST /v2/organizations/{orgId}/users/{userId}/conferencing/default",
               path: path,
               body: %{"app" => "zoom"}
             )
           )
         end)
       end},
      {"POST /v2/teams/{teamId}/users/{userId}/ooo",
       "records an out-of-office entry for a team member",
       fn credentials, _ids ->
         with_team_ooo(credentials, fn _path, _ooo -> :ok end)
       end},
      {"PATCH /v2/teams/{teamId}/users/{userId}/ooo/{oooId}",
       "edits the team out-of-office entry this run created",
       fn credentials, _ids ->
         with_team_ooo(credentials, fn path, ooo_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/teams/{teamId}/users/{userId}/ooo/{oooId}",
             params("PATCH /v2/teams/{teamId}/users/{userId}/ooo/{oooId}",
               path: Map.put(path, "oooId", ooo_id),
               body: Map.merge(ooo_window(), %{"notes" => "Edited by the certification sweep"})
             )
           )
         end)
       end},
      {"DELETE /v2/teams/{teamId}/users/{userId}/ooo/{oooId}",
       "deletes a team out-of-office entry this run created",
       fn credentials, _ids ->
         with_team_user(credentials, fn path, _team_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/teams/{teamId}/users/{userId}/ooo",
               params("POST /v2/teams/{teamId}/users/{userId}/ooo",
                 path: path,
                 body: Map.merge(ooo_window(), %{"notes" => "cal_com certification"})
               )
             )

           case Ledger.created_id(created, :id) do
             nil ->
               :ok

             ooo_id ->
               Ledger.call(credentials, "DELETE /v2/teams/{teamId}/users/{userId}/ooo/{oooId}", %{
                 "path" => Map.put(path, "oooId", ooo_id)
               })
           end
         end)
       end}
    ]
  end

  @spec with_team_user(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_team_user(credentials, fun) do
    case team_fixture(credentials) do
      nil -> :ok
      team_id -> fun.(%{"teamId" => team_id, "userId" => team_user_id(credentials)}, team_id)
    end
  end

  @spec with_team_ooo(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_team_ooo(credentials, fun) do
    with_team_user(credentials, fn path, team_id ->
      created =
        Ledger.call(
          credentials,
          "POST /v2/teams/{teamId}/users/{userId}/ooo",
          params("POST /v2/teams/{teamId}/users/{userId}/ooo",
            path: path,
            body: Map.merge(ooo_window(), %{"notes" => "cal_com certification"})
          )
        )

      case Ledger.created_id(created, :id) do
        nil ->
          :ok

        ooo_id ->
          Ledger.track(
            "DELETE /v2/teams/{teamId}/users/{userId}/ooo/{oooId}",
            Map.put(path, "oooId", ooo_id)
          )

          fun.(path, ooo_id)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Team administration: roles, workflows, booking fields, private links
  # ---------------------------------------------------------------------------

  @spec team_admin_path(term(), term()) :: map()
  defp team_admin_path(org_id, team_id), do: %{"orgId" => org_id, "teamId" => team_id}

  @spec with_team_admin(Credentials.t(), (term(), term() -> any())) :: any()
  defp with_team_admin(credentials, fun) do
    with_org_id(credentials, fn org_id ->
      case team_fixture(credentials) do
        nil -> :ok
        team_id -> fun.(org_id, team_id)
      end
    end)
  end

  @spec with_org_id(Credentials.t(), (term() -> any())) :: any()
  defp with_org_id(credentials, fun) do
    case organization_id(credentials) do
      nil -> :ok
      org_id -> fun.(org_id)
    end
  end

  # An organization team role is a fixture: created, used, deleted.
  @spec team_role(Credentials.t(), map()) :: map()
  defp team_role(credentials, path) do
    Ledger.call(
      credentials,
      "POST /v2/organizations/{orgId}/teams/{teamId}/roles",
      params("POST /v2/organizations/{orgId}/teams/{teamId}/roles",
        path: path,
        body: %{"name" => "Kithe cert team role " <> suffix(), "permissions" => ["booking.read"]}
      )
    )
  end

  @spec with_team_role(Credentials.t(), (map(), term() -> any())) :: any()
  defp with_team_role(credentials, fun) do
    with_team_admin(credentials, fn org_id, team_id ->
      path = team_admin_path(org_id, team_id)
      created = team_role(credentials, path)

      case Ledger.created_id(created, :id) do
        nil ->
          :ok

        role_id ->
          Ledger.track(
            "DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}",
            Map.put(path, "roleId", role_id)
          )

          fun.(path, role_id)
      end
    end)
  end

  @spec team_admin() :: [{String.t(), String.t(), fun()}]
  defp team_admin do
    [
      {"POST /v2/organizations/{orgId}/teams/{teamId}/roles",
       "creates a role on a team this account owns",
       fn credentials, _ids -> with_team_role(credentials, fn _path, _role -> :ok end) end},
      {"PATCH /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}",
       "edits the team role this run created",
       fn credentials, _ids ->
         with_team_role(credentials, fn path, role_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}",
             params("PATCH /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}",
               path: Map.put(path, "roleId", role_id),
               body: %{"name" => "Kithe cert team role (edited) " <> suffix()}
             )
           )
         end)
       end},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
       "grants a permission to the team role this run created",
       fn credentials, _ids ->
         with_team_role(credentials, fn path, role_id ->
           Ledger.call(
             credentials,
             "POST /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
             params("POST /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
               path: Map.put(path, "roleId", role_id),
               body: %{"permissions" => ["booking.read"]}
             )
           )
         end)
       end},
      {"PUT /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
       "replaces the permissions of the team role this run created",
       fn credentials, _ids ->
         with_team_role(credentials, fn path, role_id ->
           Ledger.call(
             credentials,
             "PUT /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
             params("PUT /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
               path: Map.put(path, "roleId", role_id),
               body: %{"permissions" => ["booking.read"]}
             )
           )
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
       "clears every permission of the team role this run created",
       fn credentials, _ids ->
         with_team_role(credentials, fn path, role_id ->
           Ledger.call(
             credentials,
             "DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
             params("DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}/permissions",
               path: Map.put(path, "roleId", role_id)
             )
           )
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}",
       "deletes a team role this run created",
       fn credentials, _ids ->
         with_team_admin(credentials, fn org_id, team_id ->
           path = team_admin_path(org_id, team_id)

           case Ledger.created_id(team_role(credentials, path), :id) do
             nil ->
               :ok

             role_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/teams/{teamId}/roles/{roleId}",
                 %{"path" => Map.put(path, "roleId", role_id)}
               )
           end
         end)
       end},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/workflows",
       "creates a workflow on a team this account owns",
       fn credentials, _ids ->
         with_team_admin(credentials, fn org_id, team_id ->
           path = team_admin_path(org_id, team_id)

           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/teams/{teamId}/workflows",
               params("POST /v2/organizations/{orgId}/teams/{teamId}/workflows",
                 path: path,
                 body: %{"name" => "Kithe cert team workflow " <> suffix()}
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/teams/{teamId}/workflows/{workflowId}",
             Map.put(path, "workflowId", Ledger.created_id(created, :id))
           )
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/teams/{teamId}/workflows/{workflowId}",
       "deletes a team workflow this run created",
       fn credentials, _ids ->
         with_team_admin(credentials, fn org_id, team_id ->
           path = team_admin_path(org_id, team_id)

           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/teams/{teamId}/workflows",
               params("POST /v2/organizations/{orgId}/teams/{teamId}/workflows",
                 path: path,
                 body: %{"name" => "Kithe cert team workflow " <> suffix()}
               )
             )

           case Ledger.created_id(created, :id) do
             nil ->
               :ok

             workflow_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/organizations/{orgId}/teams/{teamId}/workflows/{workflowId}",
                 %{"path" => Map.put(path, "workflowId", workflow_id)}
               )
           end
         end)
       end},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/event-types",
       "creates a team event type through the organization route",
       fn credentials, _ids ->
         with_team_admin(credentials, fn org_id, team_id ->
           path = team_admin_path(org_id, team_id)

           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/teams/{teamId}/event-types",
               params("POST /v2/organizations/{orgId}/teams/{teamId}/event-types",
                 path: path,
                 body: team_event_type_body(credentials)
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}",
             Map.put(path, "eventTypeId", Ledger.created_id(created, :id))
           )
         end)
       end},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "adds a booking field to a team event type through the organization route",
       fn credentials, _ids ->
         with_org_team_event_type(credentials, fn path ->
           Ledger.call(
             credentials,
             "POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
             params(
               "POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path: path,
               body: %{"slug" => "kithe-cert-field"}
             )
           )
         end)
       end},
      {"POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links",
       "creates a private link on a team event type through the organization route",
       fn credentials, _ids ->
         with_org_team_event_type(credentials, fn path ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links",
               params(
                 "POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links",
                 path: path
               )
             )

           Ledger.track(
             "DELETE /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links/{linkId}",
             Map.put(path, "linkId", Ledger.created_id(created, :link_id))
           )
         end)
       end}
    ]
  end

  # The same three booking-field routes, two of which are team-scoped: the body a
  # PATCH takes is a partial field and the body a PUT takes is the full list the
  # route's own GET returns.
  @spec team_booking_fields() :: [{String.t(), String.t(), fun()}]
  defp team_booking_fields do
    partial = [%{"slug" => "email", "required" => true}]

    [
      {"PATCH /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "edits booking fields on a team event type this run created",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           Ledger.call(
             credentials,
             "PATCH /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
             params("PATCH /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path: team_path(team_id, event_type_id),
               body: %{"bookingFields" => partial}
             )
           )
         end)
       end},
      {"PUT /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "replaces booking fields on a team event type this run created",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           path = team_path(team_id, event_type_id)

           fields =
             booking_fields(
               credentials,
               "GET /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path
             )

           Ledger.call(
             credentials,
             "PUT /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
             params("PUT /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path: path,
               body: %{"bookingFields" => fields}
             )
           )
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "edits booking fields on a team event type through the organization route",
       fn credentials, _ids ->
         with_org_team_event_type(credentials, fn path ->
           Ledger.call(
             credentials,
             "PATCH /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
             params(
               "PATCH /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path: path,
               body: %{"bookingFields" => partial}
             )
           )
         end)
       end},
      {"PUT /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
       "replaces booking fields on a team event type through the organization route",
       fn credentials, _ids ->
         with_org_team_event_type(credentials, fn path ->
           fields =
             booking_fields(
               credentials,
               "GET /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path
             )

           Ledger.call(
             credentials,
             "PUT /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
             params(
               "PUT /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields",
               path: path,
               body: %{"bookingFields" => fields}
             )
           )
         end)
       end}
    ]
  end

  # `notes` is a default system field on every event type, so deleting it proves
  # the route on an event type this run created and discards.
  @system_field_slug "notes"

  @spec booking_field_deletes() :: [{String.t(), String.t(), fun()}]
  defp booking_field_deletes do
    [
      {"DELETE /v2/event-types/{eventTypeId}/booking-fields/{slug}",
       "removes a default booking field from an event type this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           Ledger.call(
             credentials,
             "DELETE /v2/event-types/{eventTypeId}/booking-fields/{slug}",
             %{"path" => %{"eventTypeId" => event_type_id, "slug" => @system_field_slug}}
           )
         end)
       end},
      {"DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields/{slug}",
       "removes a default booking field from a team event type this run created",
       fn credentials, _ids ->
         with_team_event_type(credentials, fn team_id, event_type_id ->
           Ledger.call(
             credentials,
             "DELETE /v2/teams/{teamId}/event-types/{eventTypeId}/booking-fields/{slug}",
             %{"path" => Map.put(team_path(team_id, event_type_id), "slug", @system_field_slug)}
           )
         end)
       end},
      {"DELETE /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields/{slug}",
       "removes a default booking field from a team event type through the organization route",
       fn credentials, _ids ->
         with_org_team_event_type(credentials, fn path ->
           Ledger.call(
             credentials,
             "DELETE /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/booking-fields/{slug}",
             %{"path" => Map.put(path, "slug", @system_field_slug)}
           )
         end)
       end},
      {"PATCH /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links/{linkId}",
       "edits the private link this run created on a team event type",
       fn credentials, _ids ->
         with_org_team_event_type(credentials, fn path ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links",
               params(
                 "POST /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links",
                 path: path
               )
             )

           case Ledger.created_id(created, :link_id) do
             nil ->
               :ok

             link_id ->
               Ledger.call(
                 credentials,
                 "PATCH /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links/{linkId}",
                 params(
                   "PATCH /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}/private-links/{linkId}",
                   path: Map.put(path, "linkId", link_id),
                   body: %{"maxUsageCount" => 2}
                 )
               )
           end
         end)
       end}
    ]
  end

  @spec team_event_type_body(Credentials.t()) :: map()
  defp team_event_type_body(credentials) do
    %{
      "title" => "Kithe certification team event",
      "slug" => slug("kithe-team-cert"),
      "lengthInMinutes" => 15,
      "schedulingType" => "collective",
      "hosts" => [%{"userId" => team_user_id(credentials), "isFixed" => true}]
    }
  end

  # A team event type created through the organization route, with its org and
  # team ids in the path, tracked for deletion.
  @spec with_org_team_event_type(Credentials.t(), (map() -> any())) :: any()
  defp with_org_team_event_type(credentials, fun) do
    with_team_admin(credentials, fn org_id, team_id ->
      path = team_admin_path(org_id, team_id)

      created =
        Ledger.call(
          credentials,
          "POST /v2/organizations/{orgId}/teams/{teamId}/event-types",
          params("POST /v2/organizations/{orgId}/teams/{teamId}/event-types",
            path: path,
            body: team_event_type_body(credentials)
          )
        )

      case Ledger.created_id(created, :id) do
        nil ->
          :ok

        event_type_id ->
          Ledger.track(
            "DELETE /v2/organizations/{orgId}/teams/{teamId}/event-types/{eventTypeId}",
            Map.put(path, "eventTypeId", event_type_id)
          )

          fun.(Map.put(path, "eventTypeId", event_type_id))
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Resources that live under an event type this run creates
  # ---------------------------------------------------------------------------

  @spec event_type_children() :: [{String.t(), String.t(), fun()}]
  defp event_type_children do
    webhook = fn credentials, event_type_id ->
      Ledger.call(
        credentials,
        "POST /v2/event-types/{eventTypeId}/webhooks",
        params("POST /v2/event-types/{eventTypeId}/webhooks",
          path: %{"eventTypeId" => event_type_id},
          body: %{
            "active" => true,
            "subscriberUrl" => subscriber(),
            "triggers" => ["BOOKING_CREATED"]
          }
        )
      )
    end

    webhook_path = fn event_type_id, webhook_id ->
      %{"eventTypeId" => event_type_id, "webhookId" => webhook_id}
    end

    [
      {"POST /v2/event-types/{eventTypeId}/webhooks",
       "adds a webhook to an event type this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           created = webhook.(credentials, event_type_id)

           Ledger.track(
             "DELETE /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
             webhook_path.(event_type_id, Ledger.created_id(created, :id))
           )
         end)
       end},
      {"PATCH /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
       "edits the event-type webhook this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           with_child_webhook(credentials, event_type_id, webhook, webhook_path, fn webhook_id ->
             Ledger.call(
               credentials,
               "PATCH /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
               params("PATCH /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
                 path: webhook_path.(event_type_id, webhook_id),
                 body: %{"active" => false}
               )
             )
           end)
         end)
       end},
      {"DELETE /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
       "deletes an event-type webhook this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           case Ledger.created_id(webhook.(credentials, event_type_id), :id) do
             nil ->
               :ok

             webhook_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
                 %{"path" => webhook_path.(event_type_id, webhook_id)}
               )
           end
         end)
       end},
      {"DELETE /v2/event-types/{eventTypeId}/webhooks",
       "deletes every webhook of an event type this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           webhook.(credentials, event_type_id)

           Ledger.call(
             credentials,
             "DELETE /v2/event-types/{eventTypeId}/webhooks",
             params("DELETE /v2/event-types/{eventTypeId}/webhooks",
               path: %{"eventTypeId" => event_type_id}
             )
           )
         end)
       end},
      {"PATCH /v2/event-types/{eventTypeId}/booking-fields",
       "replaces the booking fields of an event type this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           home =
             params("PATCH /v2/event-types/{eventTypeId}/booking-fields",
               path: %{"eventTypeId" => event_type_id},
               body: %{"bookingFields" => [%{"slug" => "email", "required" => true}]}
             )

           Ledger.call(credentials, "PATCH /v2/event-types/{eventTypeId}/booking-fields", home)
         end)
       end},
      {"PUT /v2/event-types/{eventTypeId}/booking-fields",
       "replaces the booking fields of an event type this run created (PUT)",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           Ledger.call(
             credentials,
             "PUT /v2/event-types/{eventTypeId}/booking-fields",
             params("PUT /v2/event-types/{eventTypeId}/booking-fields",
               path: %{"eventTypeId" => event_type_id},
               body: %{"bookingFields" => [%{"slug" => "email", "required" => true}]}
             )
           )
         end)
       end},
      {"POST /v2/event-types/{eventTypeId}/private-links",
       "creates a private link on a claimed event type",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           created =
             Ledger.call(
               credentials,
               "POST /v2/event-types/{eventTypeId}/private-links",
               params("POST /v2/event-types/{eventTypeId}/private-links",
                 path: %{"eventTypeId" => event_type_id}
               )
             )

           Ledger.track(
             "DELETE /v2/event-types/{eventTypeId}/private-links/{linkId}",
             %{"eventTypeId" => event_type_id, "linkId" => Ledger.created_id(created, :link_id)}
           )
         end)
       end},
      {"PATCH /v2/event-types/{eventTypeId}/private-links/{linkId}",
       "edits the private link this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           with_private_link(credentials, event_type_id, fn link_id ->
             Ledger.call(
               credentials,
               "PATCH /v2/event-types/{eventTypeId}/private-links/{linkId}",
               params("PATCH /v2/event-types/{eventTypeId}/private-links/{linkId}",
                 path: %{"eventTypeId" => event_type_id, "linkId" => link_id},
                 body: %{"maxUsageCount" => 2}
               )
             )
           end)
         end)
       end},
      {"DELETE /v2/event-types/{eventTypeId}/private-links/{linkId}",
       "deletes a private link this run created",
       fn credentials, _ids ->
         with_event_type(credentials, fn event_type_id ->
           case private_link(credentials, event_type_id) do
             nil ->
               :ok

             link_id ->
               Ledger.call(
                 credentials,
                 "DELETE /v2/event-types/{eventTypeId}/private-links/{linkId}",
                 %{"path" => %{"eventTypeId" => event_type_id, "linkId" => link_id}}
               )
           end
         end)
       end}
    ]
  end

  @spec with_child_webhook(Credentials.t(), term(), function(), function(), (term() -> any())) ::
          any()
  defp with_child_webhook(credentials, event_type_id, webhook, webhook_path, fun) do
    case Ledger.created_id(webhook.(credentials, event_type_id), :id) do
      nil ->
        :ok

      webhook_id ->
        Ledger.track(
          "DELETE /v2/event-types/{eventTypeId}/webhooks/{webhookId}",
          webhook_path.(event_type_id, webhook_id)
        )

        fun.(webhook_id)
    end
  end

  @spec private_link(Credentials.t(), term()) :: term()
  defp private_link(credentials, event_type_id) do
    Ledger.created_id(
      Ledger.call(
        credentials,
        "POST /v2/event-types/{eventTypeId}/private-links",
        params("POST /v2/event-types/{eventTypeId}/private-links",
          path: %{"eventTypeId" => event_type_id}
        )
      ),
      :id
    )
  end

  @spec with_private_link(Credentials.t(), term(), (term() -> any())) :: any()
  defp with_private_link(credentials, event_type_id, fun) do
    case private_link(credentials, event_type_id) do
      nil ->
        :ok

      link_id ->
        Ledger.track("DELETE /v2/event-types/{eventTypeId}/private-links/{linkId}", %{
          "eventTypeId" => event_type_id,
          "linkId" => link_id
        })

        fun.(link_id)
    end
  end

  # The event type's own booking fields, read back so a replace reflects them.
  # The route is a parameter because each of the three routes has its own GET.
  @spec booking_fields(Credentials.t(), String.t(), map()) :: [map()]
  defp booking_fields(credentials, read_id, path) do
    verdict = Ledger.call(credentials, read_id, %{"path" => path})

    case verdict[:capture] do
      # The read answers `data: {bookingFields: [...]}`; the patch wants the list
      # itself, so the envelope is unwrapped rather than sent back whole.
      # The list goes back exactly as it came: PUT accepts the shape its own GET
      # returns, and inventing a property for a system field is refused outright
      # ("property required should not exist" on `name`).
      {%{} = typed, _package} ->
        typed.value.data |> CalCom.Codec.wire() |> Map.get("bookingFields", [])

      _none ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # The account's own settings
  # ---------------------------------------------------------------------------

  @spec account_settings() :: [{String.t(), String.t(), fun()}]
  defp account_settings do
    [
      {"PATCH /v2/me", "edits this user's own profile, then puts it back",
       fn credentials, _ids ->
         before = Ledger.call(credentials, "GET /v2/me", %{})

         restored =
           case Ledger.parsed(before) do
             %{data: data} when is_map(data) ->
               Map.take(data, [:name, :time_zone, :week_start, :locale])

             _other ->
               nil
           end

         verdict =
           Ledger.call(
             credentials,
             "PATCH /v2/me",
             params("PATCH /v2/me", body: %{"name" => "hawkyre"})
           )

         if verdict.status == "verified" and is_map(restored) do
           body =
             restored
             |> Enum.map(fn {field, value} ->
               {field |> Atom.to_string() |> Macro.underscore() |> camel(), value}
             end)
             |> Map.new()
             |> Map.reject(fn {_key, value} -> is_nil(value) end)

           restore = params("PATCH /v2/me", body: body)
           Ledger.call(credentials, "PATCH /v2/me", restore)
         end
       end}
    ]
  end

  @spec camel(String.t()) :: String.t()
  defp camel(field) do
    case String.split(field, "_") do
      [single] -> single
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
    end
  end

  # The insights endpoints compute an answer and change nothing, so they are the
  # one family the write pass calls without a fixture. `scope` is a lowercase
  # enum in the contract, and the routing ones also need a date window.
  @spec insights() :: [{String.t(), String.t(), fun()}]
  defp insights do
    bookings = [
      "POST /v2/insights/bookings/average-duration",
      "POST /v2/insights/bookings/event-trends",
      "POST /v2/insights/bookings/kpi-stats",
      "POST /v2/insights/bookings/members"
    ]

    routings = [
      "POST /v2/insights/routings/failed-bookings-by-field",
      "POST /v2/insights/routings/form-field-options",
      "POST /v2/insights/routings/form-response-headers",
      "POST /v2/insights/routings/form-responses",
      "POST /v2/insights/routings/forms-by-status",
      "POST /v2/insights/routings/routed-to-per-period"
    ]

    window = %{
      "timeZone" => "Europe/London",
      "startDate" => DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601(),
      "endDate" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "offset" => 0,
      "limit" => 10
    }

    for id <- bookings ++ routings do
      {id, "computes an insight over the last 30 days",
       fn credentials, _ids ->
         Ledger.call(credentials, id, params(id, body: Map.merge(window, %{"scope" => "org"})))
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
             cancel_params(Ledger.created_id(created, :uid))
           )
         end)
       end},
      {"POST /v2/bookings/{bookingUid}/cancel", "cancels a booking this run created",
       fn credentials, ids ->
         case Ledger.created_id(booking(credentials, ids), :uid) do
           nil ->
             :ok

           uid ->
             Ledger.call(credentials, "POST /v2/bookings/{bookingUid}/cancel", cancel_params(uid))
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
      {"PATCH /v2/bookings/{bookingUid}/location",
       "sets a location on a booking this run created",
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
               body: %{
                 "name" => @attendee["name"],
                 "email" => @second_attendee,
                 "timeZone" => @attendee["timeZone"],
                 "language" => "en"
               }
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
               body: %{"host" => false}
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

  # A booking needs a free slot on an event type the run is willing to lose, so
  # the scenario books a 15-minute event type it created for itself on a slot the
  # provider says is open — never a slot on an event type the account already had.
  @spec booking(Credentials.t(), map()) :: map()
  defp booking(credentials, _ids) do
    case free_slot(credentials) do
      nil ->
        Ledger.call(credentials, "POST /v2/bookings", %{"body" => %{}})

      {event_type_id, start} ->
        Ledger.call(
          credentials,
          "POST /v2/bookings",
          params("POST /v2/bookings",
            body: %{"start" => start, "eventTypeId" => event_type_id, "attendee" => @attendee}
          )
        )
    end
  end

  @spec booking_event_type(Credentials.t()) :: term()
  defp booking_event_type(credentials) do
    case Process.get(:certify_booking_event_type) do
      nil ->
        created =
          Ledger.call(
            credentials,
            "POST /v2/event-types",
            params("POST /v2/event-types",
              body: %{
                "title" => "Kithe certification booking",
                "slug" => slug("kithe-cert-booking"),
                "lengthInMinutes" => 15,
                "description" => "Created and deleted by the cal_com certification sweep"
              }
            )
          )

        id = Ledger.created_id(created, :id)
        Ledger.track("DELETE /v2/event-types/{eventTypeId}", "eventTypeId", id)
        Process.put(:certify_booking_event_type, id)
        id

      id ->
        id
    end
  end

  # Slots the provider reports as open, handed out one per booking so two
  # scenarios never fight over the same time.
  @spec free_slot(Credentials.t()) :: {term(), String.t()} | nil
  defp free_slot(credentials) do
    event_type_id = booking_event_type(credentials)
    if is_nil(event_type_id), do: nil, else: {event_type_id, pop_slot(credentials, event_type_id)}
  end

  @spec pop_slot(Credentials.t(), term()) :: String.t() | nil
  defp pop_slot(credentials, event_type_id) do
    slots =
      case Process.get(:certify_booking_slots) do
        nil -> fetch_slots(credentials, event_type_id)
        cached -> cached
      end

    case slots do
      [start | rest] ->
        Process.put(:certify_booking_slots, rest)
        start

      [] ->
        nil
    end
  end

  @spec fetch_slots(Credentials.t(), term()) :: [String.t()]
  defp fetch_slots(credentials, event_type_id) do
    start_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    end_at = DateTime.add(start_at, 9, :day)

    verdict =
      Ledger.call(
        credentials,
        "GET /v2/slots",
        params("GET /v2/slots",
          query: %{
            "eventTypeId" => event_type_id,
            "start" => DateTime.to_iso8601(start_at),
            "end" => DateTime.to_iso8601(end_at),
            "timeZone" => "America/Los_Angeles"
          }
        )
      )

    case verdict[:capture] do
      {false, _package} ->
        []

      {nil, _package} ->
        []

      {typed, _package} ->
        # `data` is provider-defined JSON (a date -> slots map), so it is read
        # back through the wire form rather than as a typed field.
        typed.value.data
        |> CalCom.Codec.wire()
        |> Enum.flat_map(fn {_date, rows} -> Enum.map(rows, &Map.get(&1, "start")) end)
        |> Enum.reject(&is_nil/1)

      _none ->
        []
    end
  end

  # A booking whose lifecycle step needs cancelling afterwards: it is created,
  # used once, and cancelled, so nothing outlives the scenario.
  @spec with_booking(Credentials.t(), map(), (term() -> any())) :: any()
  defp with_booking(credentials, ids, fun) do
    case Ledger.created_id(booking(credentials, ids), :uid) do
      nil ->
        :ok

      uid ->
        Ledger.track("POST /v2/bookings/{bookingUid}/cancel", cancel_params(uid)) && fun.(uid)
    end
  end

  # Cal.com requires a reason to cancel, and the document does not say so: the
  # classification for this operation carries the body the provider demands.
  @spec cancel_params(term()) :: map()
  defp cancel_params(uid) do
    %{
      "path" => %{"bookingUid" => uid},
      "body" => %{"cancellationReason" => "cal_com certification sweep"}
    }
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
