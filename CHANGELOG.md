# Changelog

Every entry names the SHA-256 of the `source/openapi.json` the release was
generated from, so a published version can be traced to its provider document.
CI fails when the current hash is absent from this file.

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
