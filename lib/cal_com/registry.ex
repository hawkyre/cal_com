defmodule CalCom.Registry do
  @moduledoc "The closed set of generated Cal.com operations."
  alias CalCom.{Operation, Operations}

  @modules [
    Operations.MeControllerGetMe
  ]
  @operations Enum.map(@modules, & &1.definition())
  @lookup Map.merge(Map.new(@operations, &{&1.id, &1}), Map.new(@operations, &{&1.key, &1}))
  @doc "Return every generated operation."
  @spec all() :: [Operation.t()]
  def all, do: @operations
  @doc "Find a fixed operation without creating atoms from input."
  @spec find(String.t() | atom()) :: Operation.t() | nil
  def find(key), do: Map.get(@lookup, key)
end
