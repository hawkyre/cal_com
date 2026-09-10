defmodule Sweep.Ledger do
  @moduledoc """
  The verdict ledger a write sweep fills, and the safety net that empties it.

  Every mutation is called through `call/3`, so the sweep ends with a verdict
  for each operation it touched — including the setup calls, because a webhook
  created to exercise a delete is itself a certified `POST /v2/webhooks`.

  A scenario that creates something registers it with `track/3`. `undo/1`
  deletes everything still tracked, newest first, so an interrupted run leaves
  the account the way it found it. Only what this run created is ever deleted.
  """

  alias CalCom.Credentials
  alias Sweep.{Client, Judge}

  @verdicts :sweep_verdicts
  @resources :sweep_resources

  @doc "Call one operation, record its verdict, and hand the verdict back."
  @spec call(Credentials.t(), String.t(), map()) :: map()
  def call(credentials, operation_id, params) do
    operation = CalCom.Registry.find(operation_id)
    started = System.monotonic_time(:millisecond)
    {_id, verdict} = Judge.call(operation, credentials, params)

    Client.log(
      "  #{String.pad_trailing(operation_id, 74)} #{verdict.status} #{verdict[:http] || ""} #{elapsed(started)}ms"
    )

    Process.put(@verdicts, Map.put(verdicts(), operation_id, verdict))
    verdict
  end

  @doc "Every verdict recorded so far."
  @spec verdicts() :: map()
  def verdicts, do: Process.get(@verdicts, %{})

  @doc "Register a resource this run created, for `undo/1` to delete."
  @spec track(String.t(), String.t(), term()) :: :ok
  def track(undo_operation, param, id) when not is_nil(id) do
    Process.put(@resources, [{undo_operation, param, id} | resources()])
    :ok
  end

  def track(_undo_operation, _param, _id), do: :ok

  @doc "What this run created and has not cleaned up yet."
  @spec resources() :: [{String.t(), String.t(), term()}]
  def resources, do: Process.get(@resources, [])

  @doc """
  Delete everything still tracked, newest first.

  A resource whose delete did not come back `verified` or `refused` is reported
  and left in the ledger, so the operator sees exactly what is still there.
  """
  @spec undo(Credentials.t()) :: [{String.t(), String.t(), term()}]
  def undo(credentials) do
    leftovers =
      Enum.reduce(resources(), [], fn {operation_id, param, id}, leftovers ->
        verdict = call(credentials, operation_id, %{"path" => %{param => id}})

        if verdict.status in ["verified", "refused"] do
          leftovers
        else
          Client.log("  LEFT BEHIND #{operation_id} #{param}=#{inspect(id)} -> #{verdict.status}")
          [{operation_id, param, id} | leftovers]
        end
      end)

    Process.put(@resources, leftovers)
    leftovers
  end

  @doc "The verdict for an id a create answered with, as the package parsed it."
  @spec created_id(map(), atom()) :: term()
  def created_id(verdict, field) do
    case verdict[:capture] do
      {typed, _package} -> get_in(typed, [:value, :data, field]) || get_in(typed, [:value, field])
      _none -> nil
    end
  end

  @doc "The parsed body of a verdict, for a scenario that has to read a field."
  @spec parsed(map()) :: term()
  def parsed(verdict) do
    case verdict[:capture] do
      {typed, _package} -> typed.value
      _none -> nil
    end
  end

  @spec elapsed(integer()) :: integer()
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
