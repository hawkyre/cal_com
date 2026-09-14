# Changelog

Every entry names the SHA-256 of the `source/openapi.json` the release was
generated from, so a published version can be traced to its provider document.
CI fails when the current hash is absent from this file.

## 0.4.0 (2026-09-14)

Generated from `source/openapi.json` with SHA-256
`44488d2fed1bfd978e3b006ca463ff43d5b5c72f028b3fa7c5620040c92c2484`.

Cancellation requests preserve an absent reason and type ordinary and seated
inputs separately. Invalid occurrence flags and seat identifiers fail before
request construction. The ordinary body keeps its published module name.

## 0.3.0 (2026-09-10)

Still generated from `source/openapi.json` with SHA-256
`44488d2fed1bfd978e3b006ca463ff43d5b5c72f028b3fa7c5620040c92c2484`; every
change below is a live-verified correction to what that document claims, or
tooling that found it.

Live certification of the read surface found seven contract bugs — all of them
cases where a real 200 from Cal.com was refused by the generated type — and each
one is now recorded in `source/live_overrides.json` with the observation that
justifies it:

- `GET /v2/bookings`: the documented `cal-api-version: 2026-05-01` times out at
  the provider (Cloudflare 524 after 125s). The operation now sends
  `2024-08-13`, which answers the same shape in under a second.
- `GetBookingsOutput_2026_05_01.pagination` accepts offset metadata as well as
  the cursor metadata the document declares, because the live API answers the
  booking list with the offset shape.
- `PaginationMetaDto.currentPage` starts at 0, not 1.
- `TeamOutputDto`/`OrgTeamOutputDto`: `logoUrl`, `calVideoLogo`, `appLogo`,
  `appIconLogo`, `bio`, `theme`, `brandColor`, `darkBrandColor`, `bannerUrl` and
  `timeFormat` are nullable.
- Every booking variant: `description`, `eventTypeId` and `eventType` are
  nullable, and the seated variants' `description` too.
- `GetAllOrgMemberships.data` and `GetTeamMembershipsOutput.data` are arrays of a
  membership, not a single membership.
- `OrgRoleOutput`, `TeamRoleOutput` and the four role input schemas: the
  `permissions` enum is incomplete — live roles carry `adminDataview.*`,
  `availability.*`, `ooo.*`, `apiKey.*` and more — so the item type is a string
  instead of a closed enum that would refuse a valid role.
- `MembershipUserOutputDto.avatarUrl` is nullable, and the four
  verified-resource outputs answer `200` with `data: null` for an id the account
  does not own, so their `data` is nullable too.

New tooling, all of it repo-only and not part of the published package:

- `scripts/certify.exs` calls every read the account can address and records a
  verdict per operation in `source/certification.json`, with a redacted capture
  per parsed response.
- `scripts/mutate.exs` does the same for mutations, inside a create → use →
  delete envelope, and refuses to run without `MUTATE_APPLY=1`.
- `scripts/coverage.py` prints what is certified and what is still open.

Mutations then found two more contract bugs, both fixed the same way:- `GetEventTypeWorkflowOutput.data` is a single workflow object, not an array.
  `POST /v2/workflows`, `GET /v2/workflows/{workflowId}` and
  `PATCH /v2/workflows/{workflowId}` all answer one object; the list endpoints
  have their own envelope. That envelope now has its own module name
  (`GetEventTypeWorkflowsOutput`), so `GetEventTypeWorkflowOutput` names the
  single-workflow shape; no module disappeared.
- Every `*WebhookOutputDto.secret` is nullable: a webhook created without one
  answers `secret: null`. The read pass had missed this because the account's
  webhook list was empty, so the list endpoint had only ever proved its
  envelope.
- `PATCH /v2/schedules/{scheduleId}` types its path id as a string while the
  GET and DELETE on the same route type it as a number, so a real schedule id
  could not be passed at all. `source/live_overrides.json` now carries the
  number, which is what the provider accepts.

The write pass then certified the other 204 operations the same way, and found
three more contract bugs plus a request body the document never mentions:

- `GetEventTypeWorkflowOutput.data` is a single workflow object, not the array
  the document declares; the list endpoints have their own envelope, which now
  has its own module name (`GetEventTypeWorkflowsOutput`).
- Every `*WebhookOutputDto.secret` is nullable — a webhook created without one
  answers `null`, which the read pass could not see because the account's
  webhook list was empty.
- `PATCH /v2/schedules/{scheduleId}` types its path id as a string where GET and
  DELETE on the same route type it as a number.
- `POST /v2/bookings/{bookingUid}/cancel` requires `cancellationReason`, and the
  document declares no request body at all; `source/live_overrides.json` now
  carries one.
- `PATCH`/`PUT` on booking fields accept the field object the route's own GET
  returns, not only the partial system field the document declares.

`source/certification.json` records a live verdict for all 349 operations and
`mix test` refuses a report that leaves one unexplained.

## 0.2.0 (2026-09-09)

Every operation the document describes — 349, up from 199 — generated from
`source/openapi.json` with SHA-256
`44488d2fed1bfd978e3b006ca463ff43d5b5c72f028b3fa7c5620040c92c2484`.

- 349 operation modules and 1242 entity modules.
- **No module changes its name.** Every module released in 0.1.0 still exists
  with the same name and shape; the 150 new operation modules and 409 new entity
  modules are additions. `source/entity_name_pins.json` records each shape's
  module name by shape hash, so a shape keeps the name it was released under
  however the inventory or registration order changes.
- `CalCom.Registry.all/0` returns 349 operations; the transport, pagination,
  webhook and error surfaces are unchanged.
- Compile cost grows with the document: see the README's compile-cost section.

## 0.1.0 (2026-09-09)

First release, generated from `source/openapi.json` with SHA-256
`44488d2fed1bfd978e3b006ca463ff43d5b5c72f028b3fa7c5620040c92c2484`.

- 199 operations of the Cal.com v2 API and their 833 typed entity modules,
  generated from the checked-in document; `CalCom.Registry.all/0` lists them.
- Transport-free: `request/2` returns a `%CalCom.Request{}` and
  `parse_response/1` takes a `%CalCom.Response{}`; no HTTP client is declared.
- Cursor, offset and body-offset pagination in `CalCom.Pagination`, which
  refuses a repeated page, a repeated cursor and contradictory metadata.
- `CalCom.Webhook` verifies HMAC-SHA256 over the exact raw bytes and parses
  every documented trigger version into its typed payload.
- Closed error reasons in `%CalCom.Error{}` with the redacted provider payload
  attached; an undocumented response shape names the field it refused.
