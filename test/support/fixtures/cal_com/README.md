# Cal.com live captures

`live_index.json` maps 142 actual response bodies to their HTTP method, route and status.
The calls ran on September 8, 2026 UTC with the isolated test account.
Account names, addresses, profile URLs, booking URLs, callback URLs and secrets are redacted.
Field names, null values, collection contents and response structure are retained.

Each fixture includes the operation, date, attempt key, status and original redacted request parameters.
Its body field retains the complete redacted response text.
The private original captures and cost keys use the matching `.connector-test-cal-NNN` number.
Attempt 029 received no HTTP response. A later read found its created webhook; cleanup removed it.
Attempts 023 and 030 failed input validation before HTTP and have no response fixture.
The 14 webhook fixtures contain actual deliveries for six booking events, using version `2026-07-27`.
The private verifier checks each original body with its actual signature and the disposable subscription secret.
It asserts typed parsing, complete field retention, and a booking UID from authenticated response captures.
It rejects a changed body, wrong secret, duplicate signature headers, and duplicate version headers.
The stored SHA-256 identifies each original body. These redacted copies cannot reproduce its signature.
The recorded tests check payload parsing; separate synthetic unit cases check signature failures.
OAuth, organization access, and webhook version `2021-10-20` remain unverified.
