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
    {:cal_com, git: "git@github.com:hawkyre/cal_com.git", tag: "v0.1.0"}
  ]
end
```

## First call

```elixir
alias CalCom.{Credentials, Response}
alias CalCom.Operations.MeControllerGetMe

{:ok, input} = MeControllerGetMe.parse_input(%{})
{:ok, request} = MeControllerGetMe.request(input, %Credentials{kind: :api_key, token: key})

%{status: status, headers: headers, body: body} = Req.request!(method: request.method, url: request.url, headers: request.headers, body: request.body)

case MeControllerGetMe.parse_response(%Response{status: status, headers: headers, body: body}) do
  {:ok, result} -> result
  {:error, %CalCom.Error{reason: reason}} -> handle(reason)
end
```

`Req` is an example, not a dependency: the package declares no HTTP client.

## Errors

`%CalCom.Error{}` carries a closed `reason` and the redacted provider `payload`.
A response body that does not match its generated contract yields
`reason: :invalid_body` with the offending field in `payload`; the fix is a
generator run and a release, not a rescue clause.

## Regenerating from the spec

Everything under `lib/cal_com/entities/`, `lib/cal_com/operations/`,
`lib/cal_com/registry.ex` and `source/*_contracts_*.json` is generated from
`source/openapi.json`:

```console
python3 source/generate.py          # writes the files
python3 source/generate.py --check  # fails when the files are stale (CI)
```

The generator reads `source/SOURCE_HASH` first and refuses to run when the
SHA-256 of `source/openapi.json` differs, printing both hashes. A spec refresh
therefore cannot land without updating the hash in the same commit. The
operations generated are exactly the ones listed in `source/inventory.json`.

## Development

```console
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
python3 -m unittest test/generate_test.py
```

The package keeps the strict bar it was extracted under: every public function
has a `@doc` and a `@spec`, private functions have a `@spec`, comment blocks are
capped at two lines, and `struct!` is banned — all enforced by the custom checks
in `priv/credo_checks/`.
