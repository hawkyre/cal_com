defmodule CalCom.Operation do
  @moduledoc "One generated Cal.com operation and its concrete types."
  @enforce_keys [:key, :id, :method, :path, :module, :input_module]
  defstruct [
    :key,
    :id,
    :method,
    :path,
    :module,
    :input_module,
    :version,
    :media_type,
    :page_size,
    :page_key,
    outputs: [],
    pagination: :none
  ]

  @typedoc "One versioned operation and its generated concrete types."
  @type t :: %__MODULE__{
          key: atom(),
          id: String.t(),
          method: atom(),
          path: String.t(),
          module: module(),
          input_module: module(),
          version: String.t() | nil,
          media_type: String.t() | nil,
          page_size: pos_integer() | nil,
          page_key: String.t() | nil,
          outputs: [CalCom.Output.t()],
          pagination: :none | :cursor | :offset | :body_offset
        }
end

defmodule CalCom.Output do
  @moduledoc "A typed success response for one documented status."
  alias CalCom.Rule
  @enforce_keys [:status, :module, :rule]
  defstruct [:status, :module, :rule, empty?: false]
  @typedoc "A fixed response variant."
  @type t :: %__MODULE__{
          status: pos_integer(),
          module: module(),
          rule: Rule.t(),
          empty?: boolean()
        }
end

defmodule CalCom.Call do
  @moduledoc "One operation with its concrete parsed input."
  alias CalCom.Operation
  @enforce_keys [:operation, :input]
  @derive {Inspect, only: [:operation]}
  defstruct [:operation, :input]
  @typedoc "A parsed provider call. The operation fixes the input module."
  @type t :: %__MODULE__{operation: Operation.t(), input: struct()}
end

defmodule CalCom.Context do
  @moduledoc "The explicit call and credentials for a shared connector walk."
  alias CalCom.{Call, Credentials}
  @enforce_keys [:call, :credentials]
  @derive {Inspect, only: []}
  defstruct [:call, :credentials]
  @typedoc "A typed walk input."
  @type t :: %__MODULE__{call: Call.t(), credentials: Credentials.t()}
end

defmodule CalCom.PageMeta do
  @moduledoc "Typed pagination evidence for one provider response."
  defstruct status: nil,
            cursor: nil,
            has_more: nil,
            has_next_page: nil,
            returned_items: nil,
            remaining_items: nil,
            total_items: nil,
            count: 0,
            total: nil,
            retry_after: nil

  @typedoc "A page continuation, never a synchronization watermark."
  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          cursor: String.t() | nil,
          has_more: boolean() | nil,
          has_next_page: boolean() | nil,
          returned_items: non_neg_integer() | nil,
          remaining_items: non_neg_integer() | nil,
          total_items: non_neg_integer() | nil,
          count: non_neg_integer(),
          total: non_neg_integer() | nil,
          retry_after: String.t() | nil
        }
end
