# Certification sweep against the live Cal.com API.
#
#   CAL_COM_API_KEY=... mix run scripts/certify.exs
#
# Calls every read operation the account can address, checks that the response
# parses into its generated type, and writes:
#
#   source/certification.json                  per-operation verdict and reason
#   test/support/fixtures/cal_com/certified/   a redacted capture per read that parsed
#   test/support/fixtures/cal_com/unparsed/    the body of any 2xx the contract refused
#
# Reads only: mutations are reported as `write` and are exercised by
# `scripts/mutate.exs`. Nothing here creates, changes or deletes provider data.
Code.require_file("sweep/client.exs", __DIR__)
Code.require_file("sweep/discover.exs", __DIR__)
Code.require_file("sweep/inputs.exs", __DIR__)
Code.require_file("sweep/judge.exs", __DIR__)
Code.require_file("sweep/report.exs", __DIR__)

Sweep.Client.start()

defmodule Certify do
  @moduledoc """
  Discovers the account's ids, calls every read operation once, and records what
  each one answered.

  A call the provider throttles is not a verdict: those operations are swept
  again after a cooldown, up to `@throttle_rounds` times, and only then recorded
  as `throttled`.
  """

  alias CalCom.{Credentials, Registry}
  alias Sweep.{Client, Discover, Judge, Report}

  @throttle_rounds 3
  @cooldown_ms 65_000

  @doc "Discover the account's ids, sweep every read, write the report."
  @spec run(Credentials.t()) :: :ok
  def run(credentials) do
    account = Discover.account(credentials)
    discovered = Discover.ids(credentials, account)
    IO.puts("account: user=#{account.user_id} org=#{inspect(account.organization_id)}")
    IO.puts("discovered ids: #{inspect(Map.new(discovered, fn {k, v} -> {k, length(v)} end))}")

    verdicts = sweep(Registry.all() |> Enum.sort_by(& &1.id), credentials, discovered, %{}, 1)

    Report.write(verdicts, account)
  end

  # A throttled call is retried in a later round after a cooldown, so the report
  # never records a verdict the provider did not give.
  @spec sweep([CalCom.Operation.t()], Credentials.t(), map(), map(), pos_integer()) :: map()
  defp sweep(operations, credentials, discovered, verdicts, round)
       when round <= @throttle_rounds do
    {verdicts, throttled} =
      Enum.reduce(operations, {verdicts, []}, fn operation, {verdicts, throttled} ->
        record(operation, credentials, discovered, verdicts, throttled)
      end)

    case Enum.reverse(throttled) do
      [] ->
        verdicts

      pending ->
        IO.puts(
          "round #{round}: #{length(pending)} throttled, cooling down #{div(@cooldown_ms, 1000)}s"
        )

        Process.sleep(@cooldown_ms)
        sweep(pending, credentials, discovered, verdicts, round + 1)
    end
  end

  defp sweep(operations, credentials, discovered, verdicts, round) do
    # The last round records whatever the provider said: still throttled stays a
    # `throttled` verdict instead of a guess about the operation.
    IO.puts("round #{round}: #{length(operations)} still throttled")

    Enum.reduce(operations, verdicts, fn operation, verdicts ->
      record(operation, credentials, discovered, verdicts, [])
    end)
  end

  @spec record(CalCom.Operation.t(), Credentials.t(), map(), map(), list()) :: {map(), list()}
  defp record(operation, credentials, discovered, verdicts, throttled) do
    started = System.monotonic_time(:millisecond)
    {id, verdict} = Judge.judge(operation, credentials, discovered)
    ms = System.monotonic_time(:millisecond) - started

    Client.log("  #{pad(id)} #{verdict.status} #{verdict[:http] || ""} #{ms}ms")

    case verdict.status do
      "throttled" -> {verdicts, [operation | throttled]}
      _recorded -> {Map.put(verdicts, id, verdict), throttled}
    end
  end

  @spec pad(String.t()) :: String.t()
  defp pad(id), do: String.pad_trailing(id, 72)
end

Certify.run(%CalCom.Credentials{kind: :api_key, token: System.fetch_env!("CAL_COM_API_KEY")})
