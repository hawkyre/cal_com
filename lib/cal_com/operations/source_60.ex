alias CalCom.Operations

defmodule Operations.TeamsControllerGetTeams do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_60.json", __MODULE__}
end

defmodule Operations.TeamsControllerGetTeam do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_60.json", __MODULE__}
end

defmodule Operations.TeamsControllerUpdateTeam do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_60.json", __MODULE__}
end

defmodule Operations.TeamsControllerDeleteTeam do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_60.json", __MODULE__}
end

defmodule Operations.TeamsBookingsControllerGetAllTeamBookings do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_60.json", __MODULE__}
end
