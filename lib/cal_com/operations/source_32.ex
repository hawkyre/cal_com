alias CalCom.Operations

defmodule Operations.CalendarsControllerSyncCredentials do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_32.json", __MODULE__}
end

defmodule Operations.CalendarsControllerCheck do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_32.json", __MODULE__}
end

defmodule Operations.CalendarsControllerDeleteCalendarCredentials do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_32.json", __MODULE__}
end

defmodule Operations.ConferencingControllerConnect do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_32.json", __MODULE__}
end

defmodule Operations.ConferencingControllerRedirect do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_32.json", __MODULE__}
end
