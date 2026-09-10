defmodule Sweep.Client do
  @moduledoc """
  The one paced HTTP exchange both live sweeps use.

  Req is a dev-only dependency (`runtime: false`), so its Finch pool is not
  started for us: call `start/0` before the first request. Calls are spaced to
  stay inside the account's request budget, and a 429 is reported to the caller
  as a response — a throttled call is a provider answer, not a verdict, and the
  sweep that owns it decides when to try again.
  """

  alias CalCom.{Credentials, Error, Operation, Registry, Response}

  @calls_per_second 1

  @doc "Start the Req pool the sweeps need."
  @spec start() :: :ok
  def start do
    {:ok, _started} = Application.ensure_all_started(:req)
    :ok
  end

  @doc "Build the request for an operation, send it, and return the raw response."
  @spec exchange(Operation.t(), Credentials.t(), map()) :: {:ok, Response.t()} | {:error, term()}
  def exchange(operation, credentials, params) do
    with {:ok, input} <- operation.input_module.parse(params),
         {:ok, request} <- operation.module.request(input, credentials) do
      send_request(request)
    end
  end

  @doc "Call an operation by registry id and parse its response."
  @spec call(Credentials.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(credentials, id, params) do
    case Registry.find(id) do
      nil ->
        {:error, :unknown_operation}

      operation ->
        case exchange(operation, credentials, params) do
          {:ok, package} -> operation.module.parse_response(package)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The provider's throttle note, when the response is a 429."
  @spec throttle_note(Response.t()) :: String.t() | nil
  def throttle_note(%Response{status: 429} = package) do
    case Response.header(package, "retry-after") do
      nil -> "provider answered 429 with no retry-after"
      seconds -> "provider answered 429, retry after #{String.trim(seconds)}s"
    end
  end

  def throttle_note(_package), do: nil

  @spec send_request(CalCom.Request.t(), non_neg_integer()) ::
          {:ok, Response.t()} | {:error, term()}
  defp send_request(request, retries \\ 1) do
    pace()

    case Req.request(
           method: request.method,
           url: request.url,
           headers: request.headers,
           body: request.body,
           decode_body: false,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, %Response{status: status, headers: headers, body: body}}

      # A single socket timeout is the network, not the provider.
      {:error, %Req.TransportError{}} when retries > 0 ->
        send_request(request, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec pace() :: :ok
  defp pace do
    spacing = div(1000, @calls_per_second)

    # `monotonic_time/1` is negative on this VM, so the marker starts as nil
    # rather than 0: `now - 0` would look like an eternity still to wait.
    case Process.get(:sweep_last_call) do
      nil ->
        :ok

      last ->
        wait = spacing - (System.monotonic_time(:millisecond) - last)
        if wait > 0, do: Process.sleep(wait)
    end

    Process.put(:sweep_last_call, System.monotonic_time(:millisecond))
    :ok
  end

  @doc "The typed error an unparsed response carries, for a readable report."
  @spec describe(term()) :: String.t()
  def describe(%Error{reason: reason, payload: payload}),
    do: "#{inspect(reason)} #{inspect(payload)}"

  def describe(other), do: inspect(other)

  @doc """
  Append one line of progress to `tmp/sweep.log` and echo it.

  A sweep runs for minutes and writes its report at the end, so it keeps a
  line-per-call trail on disk: stdout is buffered when it is not a terminal and
  would otherwise show nothing until the run finished.
  """
  @spec log(String.t()) :: :ok
  def log(line) do
    IO.puts(line)
    File.mkdir_p!("tmp")
    File.write!("tmp/sweep.log", line <> "\n", [:append])
    :ok
  end
end
