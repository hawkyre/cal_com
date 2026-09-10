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

  @doc """
  Register a resource this run created, for `undo/1` to clean up.

  The whole call is recorded, not just one id: an organization resource needs
  `orgId` alongside it, and cancelling a booking needs a body, so a cleanup that
  loses a required part never reaches the provider at all.
  """
  @spec track(String.t(), map() | String.t(), term()) :: :ok
  def track(undo_operation, %{"path" => _path} = params, _id),
    do: put_resource(undo_operation, params)

  def track(undo_operation, path, _id) when is_map(path),
    do: put_resource(undo_operation, %{"path" => path})

  def track(undo_operation, param, _id),
    do: put_resource(undo_operation, %{"path" => %{param => nil}})

  @doc "Register a resource by the call that cleans it up."
  @spec track(String.t(), map()) :: :ok
  def track(undo_operation, params), do: put_resource(undo_operation, params)

  @spec put_resource(String.t(), map()) :: :ok
  defp put_resource(operation_id, %{"path" => path} = params) do
    # A path with a missing id would only produce a call the provider never sees,
    # so it is not recorded at all.
    if Enum.all?(path, fn {_param, value} -> not is_nil(value) end) do
      Process.put(@resources, [{operation_id, params} | resources()])
    end

    :ok
  end

  @doc "What this run created and has not cleaned up yet."
  @spec resources() :: [{String.t(), map()}]
  def resources, do: Process.get(@resources, [])

  @doc """
  Delete everything still tracked, newest first.

  A resource whose delete did not come back `verified` or `refused` is reported
  and left in the ledger, so the operator sees exactly what is still there.
  """
  @spec undo(Credentials.t()) :: [{String.t(), map()}]
  def undo(credentials) do
    leftovers = delete_all(credentials, resources(), [])

    # A delete the provider throttled is worth one more attempt after a pause:
    # leaving a certification team behind is worse than a slower run.
    leftovers =
      if leftovers == [] do
        []
      else
        Client.log("  undo: #{length(leftovers)} left, cooling down 65s and retrying")
        Process.sleep(65_000)
        delete_all(credentials, leftovers, [])
      end

    Process.put(@resources, leftovers)
    leftovers
  end

  @spec delete_all(Credentials.t(), [{String.t(), map()}], [{String.t(), map()}]) :: [
          {String.t(), map()}
        ]
  defp delete_all(credentials, resources, leftovers) do
    Enum.reduce(resources, leftovers, fn {operation_id, params}, leftovers ->
      verdict = call(credentials, operation_id, params)

      if verdict.status in ["verified", "refused"] do
        leftovers
      else
        Client.log("  LEFT BEHIND #{operation_id} #{inspect(params)} -> #{verdict.status}")
        [{operation_id, params} | leftovers]
      end
    end)
  end

  @doc """
  The id a create answered with, as the package parsed it.

  Generated entities are structs, not maps with the Access behaviour, so the
  value is walked with `Map.get/2` rather than `get_in/2`. Some creates nest the
  created object one level down (`data: {role: {...}}`), so a miss looks once
  inside the values of `data` before giving up.
  """
  @spec created_id(map(), atom()) :: term()
  def created_id(verdict, field) do
    case verdict[:capture] do
      # A refused body rides in the same slot as a parsed one, marked false; a
      # capture that never parsed has no id to read.
      {false, _package} -> nil
      {nil, _package} -> nil
      {typed, _package} -> maybe_id(Map.get(typed, :value), field)
      _none -> nil
    end
  end

  @spec maybe_id(term(), atom()) :: term()
  defp maybe_id(%{data: data}, field) when is_map(data),
    do: Map.get(data, field) || nested_id(data, field)

  defp maybe_id(value, field) when is_map(value), do: Map.get(value, field)
  defp maybe_id(_value, _field), do: nil

  @spec nested_id(map(), atom()) :: term()
  defp nested_id(data, field) do
    Enum.find_value(Map.values(data), fn
      %{} = inner -> Map.get(inner, field)
      _other -> nil
    end)
  end

  @doc "The parsed body of a verdict, for a scenario that has to read a field."
  @spec parsed(map()) :: term()
  def parsed(verdict) do
    case verdict[:capture] do
      {false, _package} -> nil
      {nil, _package} -> nil
      {typed, _package} -> Map.get(typed, :value)
      _none -> nil
    end
  end

  @spec elapsed(integer()) :: integer()
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
