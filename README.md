# cal_com

A typed, transport-free client for the [Cal.com](https://cal.com) v2 API.

The package builds a request from typed input and parses a response into typed
structs. It never opens a socket: you send `%CalCom.Request{}` with whatever
HTTP client you already use and hand the status, headers and body back as
`%CalCom.Response{}`.

* Every operation has a generated module with `parse_input/1`, `request/2` and
  `parse_response/1`.
* Every documented field is typed. Unknown response fields are preserved, not
  dropped; an undocumented shape fails with `%CalCom.Error{reason: :invalid_body}`
  naming the field and carrying the raw payload.
* Failures are closed reasons (`:unauthorized`, `:forbidden`, `:not_found`,
  `:rate_limited`, `{:http, status}`, ...) — never a bare map.

## Install

Depend on it by git ref:

```elixir
def deps do
  [
    {:cal_com, git: "git@github.com:hawkyre/cal_com.git", tag: "v0.2.0"}
  ]
end
```

## First call

```elixir
alias CalCom.{Credentials, Response}
alias CalCom.Operations.MeControllerGetMe

{:ok, input} = MeControllerGetMe.parse_input(%{})
{:ok, request} = MeControllerGetMe.request(input, %Credentials{kind: :api_key, token: key})

%{status: status, headers: headers, body: body} =
  Req.request!(
    method: request.method,
    url: request.url,
    headers: request.headers,
    body: request.body,
    decode_body: false
  )

case MeControllerGetMe.parse_response(%Response{status: status, headers: headers, body: body}) do
  {:ok, result} -> result
  {:error, %CalCom.Error{reason: reason}} -> handle(reason)
end
```

`Req` is an example, not a dependency: the package declares no HTTP client.

`%CalCom.Response{body: body}` takes the **raw bytes**. Most clients decode JSON for you
by default — with `Req` that is `decode_body: false`, as above — and handing the package a
decoded map fails its `binary()` contract. Your client's own decoding is your business; the
package parses the bytes.

## Walking a paginated collection

```elixir
{:ok, call} = CalCom.Call.parse(%{"operation" => "GET /v2/bookings", "params" => %{"query" => %{"limit" => 50}}})
context = %CalCom.Context{call: call, credentials: credentials}

request = CalCom.Pagination.first(call.operation.key, context, nil)
# send `request`, then:
next = CalCom.Pagination.next(call.operation.key, response, request)
```

`next/3` returns the next request, `nil` when the walk is finished, or
`{:error, %CalCom.Error{reason: :invalid_cursor}}` when the provider repeats a
page or a cursor or returns contradictory metadata — a walk never loops
silently.

## Webhooks

```elixir
case CalCom.Webhook.parse(raw_body, headers, secret: secret) do
  {:ok, %CalCom.Webhook{event: event, version: version, value: payload}} -> handle(event, payload)
  {:error, %CalCom.Error{reason: :unauthorized}} -> reject()
end
```

`verify/3` checks the HMAC over the exact raw body bytes and `parse/3` refuses a
repeated signature or version header, an unsupported version and an unknown
trigger before your domain sees the delivery. The secret is passed in, never
read from configuration.

`CalCom.Registry.all/0` lists every generated operation; `Registry.find/1`
takes its method-route id or key.

## Errors

`%CalCom.Error{}` carries a closed `reason` and the redacted provider `payload`.
A response body that does not match its generated contract yields
`reason: :invalid_body` with the offending field in `payload`; the fix is a
generator run and a release, not a rescue clause.

## Regenerating from the spec

Everything under `lib/cal_com/entities/`, `lib/cal_com/operations/`,
`lib/cal_com/registry.ex`, `lib/cal_com/webhook_payloads.ex` and
`source/*_contracts_*.json` is generated from `source/openapi.json`:

```console
python3 source/generate.py          # writes the files
python3 source/generate.py --check  # fails when the files are stale (CI)
```

The generator reads `source/SOURCE_HASH` first and refuses to run when the
SHA-256 of `source/openapi.json` differs, printing both hashes. A spec refresh
therefore cannot land without updating the hash in the same commit. The
operations generated are exactly the ones listed in `source/inventory.json`.

`source/entity_name_pins.json` maps each shape's hash to its module name. A
shape that already has a module keeps that name whatever the inventory or the
registration order does, so widening the inventory adds modules instead of
renaming them. A brand-new shape takes the name the inventory gives it and is
pinned on the next write.

## Live certification

`source/certification.json` records one verdict per operation, taken from a real
call against a real account:

```console
CAL_COM_API_KEY=... mix run scripts/certify.exs   # reads
MUTATE_APPLY=1 CAL_COM_API_KEY=... mix run scripts/mutate.exs   # mutations
python3 scripts/coverage.py                        # the table below
python3 scripts/coverage.py --require-complete      # fails on anything unexplained (CI)
```

| verdict       | meaning                                                                    |
| ------------- | -------------------------------------------------------------------------- |
| `verified`    | the provider answered 2xx and the body parsed into its generated type       |
| `refused`     | the provider answered a documented failure, and the client classified it    |
| `unreachable` | the account owns no id for a path parameter, so the success path is out of reach; the call is still made once with an id that cannot exist, and its classified answer is recorded under `probe` |
| `declined`    | the operation cannot be exercised on the test account at all — each entry carries the reason (a third-party OAuth grant, a platform account, real money, a device token) |
| `throttled`   | the provider rate-limited the call; the sweep retries it in a later round    |
| `write`       | a mutation the write pass has not reached yet                                |

`mix test` asserts the same thing from the other side: every operation in the
registry has exactly one verdict, every `declined` entry carries a reason, every
`unreachable` one carries the probe that called it, and no live response is
refused by its own contract. CI runs both, so a report that leaves an operation
unexplained, or a contract that starts refusing live bodies, fails the build
instead of sitting quietly in a JSON file.

Every capture a parsed call produced is kept, redacted, under
`test/support/fixtures/cal_com/certified/`; a 2xx the contract refused is kept
under `unparsed/` instead, so a shape bug leaves its evidence behind. Live
corrections the spec gets wrong are recorded in `source/live_overrides.json`,
each with the observation that justifies it — for example
`PaginationMetaDto.currentPage` starting at 0, `TeamOutputDto` fields the
provider sends as an explicit null, `GetEventTypeWorkflowOutput.data` being one
object rather than the array the document declares, and `GET /v2/bookings`,
whose documented `2026-05-01` version times out at the provider (Cloudflare 524
after 125s) while `2024-08-13` answers the same shape in under a second.

Two provider behaviours a caller should know about:

- `POST /v2/teams` answers `201` with `data.pendingTeam` and a Stripe
  `paymentLink`; the team does not exist until the payment completes, so a
  follow-up `PATCH` or `DELETE` on that id answers 403 or 404. The response
  parses, and nothing was created to clean up.
- `POST /v2/bookings/{bookingUid}/cancel` accepts an optional reason. Its standard
  input supports `cancelSubsequentBookings`; its seated input requires `seatUid`.
  Each input rejects fields from the other variant before a request is built.

A `verified` read is weaker evidence when the collection it read was empty: the
envelope parsed, but no row did. That is how the webhook `secret` null stayed
hidden until a mutation created a webhook and read it back.

## Compile cost

The package compiles 139 files that define 349 operations and 1242 entity
modules: about 31 seconds of wall time on a 20-core machine, roughly five
minutes of CPU, paid once per build volume. Incremental builds after that touch
only what changed; a fresh `_build` pays the whole cost again.

## Releasing

Releases are cut by hand from a maintainer's machine; CI only proves the
tarball builds. A release that is not traceable to its provider document is
not a release, so the CHANGELOG entry and the hash move together:

1. `python3 source/generate.py --check`, `mix test`, `mix credo --strict` and
   `mix dialyzer` are green on `main`.
2. Add a CHANGELOG entry naming the current `source/SOURCE_HASH`.
3. Bump `@version` in `mix.exs`, commit, and push.
4. `git tag vX.Y.Z && git push origin vX.Y.Z` — CI runs the suite on the tag.
5. `mix hex.publish` with two-factor confirmation.

## Development

```console
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
python3 test/generate_test.py
```

The package keeps the strict bar it was extracted under: every public function
has a `@doc` and a `@spec`, private functions have a `@spec`, comment blocks are
capped at two lines, and `struct!` is banned — all enforced by the custom checks
in `priv/credo_checks/`.
