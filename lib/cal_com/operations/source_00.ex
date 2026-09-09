alias CalCom.Operations

defmodule Operations.MeControllerGetMe do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_00.json", __MODULE__}
end
