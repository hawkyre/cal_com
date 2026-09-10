defmodule CalCom.WalkState do
  @moduledoc "Typed progress evidence for one Cal.com walk."
  defstruct seen_cursors: MapSet.new(), seen_pages: MapSet.new()
  @typedoc "Per-walk continuation history."
  @type t :: %__MODULE__{seen_cursors: MapSet.t(String.t()), seen_pages: MapSet.t(binary())}
end

defmodule CalCom.Pagination do
  @moduledoc "Pure continuation decisions for each Cal.com pagination scheme."
  alias CalCom.{Call, Codec, Context, PageMeta, RequestBuilder, ResponseParser, WalkState}

  alias CalCom.{Error, Request, Response}

  @doc "Prepare a supported call with explicit credentials."
  @spec first(atom(), Context.t(), String.t() | nil) :: Request.t() | {:error, Error.t()}
  def first(entity, %Context{call: %Call{operation: operation}} = context, cursor) do
    with true <- entity == operation.key,
         {:ok, call} <- prepare(context.call, cursor),
         {:ok, request} <- RequestBuilder.request(call, context.credentials) do
      state = %WalkState{
        seen_cursors: if(is_nil(cursor), do: MapSet.new(), else: MapSet.new([cursor]))
      }

      Request.put_private(request, cal_com_state: state)
    else
      false -> invalid("operation mismatch")
      {:error, _error} = error -> error
    end
  end

  @doc "Advance without repeating a page or silently accepting broken metadata."
  @spec next(atom(), Response.t(), Request.t()) :: Request.t() | nil | {:error, Error.t()}
  def next(entity, response, %Request{private: %{cal_com: %Context{} = context}} = previous) do
    operation = context.call.operation
    state = Map.get(previous.private, :cal_com_state, %WalkState{})
    digest = :crypto.hash(:sha256, response.body)

    with true <- entity == operation.key,
         false <- MapSet.member?(state.seen_pages, digest),
         {:ok, result} <- ResponseParser.parse(operation, response) do
      meta = ResponseParser.meta(response, result)
      state = %{state | seen_pages: MapSet.put(state.seen_pages, digest)}
      advance(context, meta, state)
    else
      true -> invalid("provider repeated a page")
      false -> invalid("operation mismatch")
      {:error, _error} = error -> error
    end
  end

  def next(_entity, _response, _previous), do: invalid("missing walk context")

  @spec prepare(Call.t(), String.t() | nil) :: {:ok, Call.t()} | {:error, Error.t()}
  defp prepare(%Call{operation: %{pagination: :none}} = call, nil),
    do: update(call, "query", fn query -> Map.delete(query, "hostsLimit") end)

  defp prepare(%Call{operation: %{pagination: :cursor}} = call, cursor) do
    with {:ok, call} <- page_size(call, "query") do
      if is_nil(cursor),
        do: {:ok, call},
        else: update(call, "query", &Map.put(&1, "cursor", cursor))
    end
  end

  defp prepare(%Call{operation: %{pagination: :offset}} = call, nil) do
    with {:ok, call} <- page_size(call, "query"),
         do: update(call, "query", &Map.put_new(&1, "skip", 0))
  end

  defp prepare(%Call{operation: %{pagination: :body_offset}} = call, nil) do
    with {:ok, call} <- page_size(call, "body"),
         do: update(call, "body", &Map.put_new(&1, "offset", 0))
  end

  defp prepare(_call, _cursor), do: invalid("unsupported cursor")

  @spec page_size(Call.t(), String.t()) :: {:ok, Call.t()} | {:error, Error.t()}
  defp page_size(%Call{operation: operation} = call, part) do
    params = Codec.object_wire(call.input)
    key = operation.page_key || "limit"
    size = get_in(params, [part, key]) || operation.page_size

    if is_number(size) and size > 0,
      do: update(call, part, &Map.put(&1, key, size)),
      else: invalid("caller must supply a positive page size")
  end

  @spec advance(Context.t(), PageMeta.t(), WalkState.t()) ::
          Request.t() | nil | {:error, Error.t()}
  defp advance(%Context{call: %{operation: %{pagination: :none}}}, _meta, _state), do: nil

  defp advance(%Context{call: %{operation: %{pagination: :cursor}}} = context, meta, state) do
    case {meta.has_more, meta.cursor} do
      {false, nil} ->
        nil

      # Cal.com's organization booking list documents a cursor and answers with
      # offset metadata: an explicit "no next page" is the stop a walk needs.
      {nil, nil} when meta.has_next_page == false ->
        nil

      {true, cursor} when is_binary(cursor) and byte_size(cursor) > 0 ->
        if MapSet.member?(state.seen_cursors, cursor) do
          invalid("provider repeated a cursor")
        else
          state = %{state | seen_cursors: MapSet.put(state.seen_cursors, cursor)}
          continue(context, "query", "cursor", cursor, state)
        end

      _broken ->
        invalid("contradictory cursor metadata")
    end
  end

  defp advance(%Context{call: %{operation: %{pagination: :offset}}} = context, meta, state) do
    offset = get_in(Codec.object_wire(context.call.input), ["query", "skip"]) || 0

    cond do
      inconsistent_offset?(meta, offset) ->
        invalid("contradictory offset metadata")

      meta.has_next_page == false ->
        nil

      meta.count == 0 and meta.has_next_page == true ->
        invalid("empty page claims more results")

      meta.count == 0 ->
        nil

      true ->
        continue(context, "query", "skip", offset + meta.count, state)
    end
  end

  defp advance(%Context{call: %{operation: %{pagination: :body_offset}}} = context, meta, state) do
    offset = get_in(Codec.object_wire(context.call.input), ["body", "offset"]) || 0

    cond do
      not is_integer(meta.total) or meta.total < 0 -> invalid("missing total")
      offset + meta.count > meta.total -> invalid("inconsistent total")
      offset + meta.count == meta.total -> nil
      meta.count == 0 -> invalid("empty page before total")
      true -> continue(context, "body", "offset", offset + meta.count, state)
    end
  end

  @spec inconsistent_offset?(PageMeta.t(), non_neg_integer()) :: boolean()
  defp inconsistent_offset?(meta, offset) do
    (is_number(meta.returned_items) and meta.returned_items != meta.count) or
      (is_number(meta.remaining_items) and meta.remaining_items < 0) or
      (meta.has_next_page == false and is_number(meta.remaining_items) and
         meta.remaining_items > 0) or
      (meta.has_next_page == true and meta.remaining_items == 0) or
      inconsistent_total?(meta, offset)
  end

  @spec inconsistent_total?(PageMeta.t(), non_neg_integer()) :: boolean()
  defp inconsistent_total?(
         %{total_items: total, remaining_items: remaining, count: count},
         offset
       )
       when is_number(total) and is_number(remaining), do: offset + count + remaining != total

  defp inconsistent_total?(_meta, _offset), do: false

  @spec continue(Context.t(), String.t(), String.t(), term(), WalkState.t()) ::
          Request.t() | {:error, Error.t()}
  defp continue(context, part, key, value, state) do
    with {:ok, call} <- update(context.call, part, &Map.put(&1, key, value)),
         {:ok, request} <- RequestBuilder.request(call, context.credentials) do
      Request.put_private(request, cal_com_state: state)
    end
  end

  @spec update(Call.t(), String.t(), (map() -> map())) :: {:ok, Call.t()} | {:error, Error.t()}
  defp update(call, part, update) do
    params = Codec.object_wire(call.input)
    changed = update.(Map.get(params, part, %{}))

    params =
      if map_size(changed) == 0 and not Map.has_key?(params, part),
        do: params,
        else: Map.put(params, part, changed)

    with {:ok, input} <- call.operation.input_module.parse(params),
         do: {:ok, %{call | input: input}}
  end

  @spec invalid(String.t()) :: {:error, Error.t()}
  defp invalid(reason), do: {:error, %Error{reason: :invalid_cursor, payload: reason}}
end
