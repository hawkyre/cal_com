alias CalCom.Operations

defmodule Operations.OrganizationsTeamsControllerGetMyTeams do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_02.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsControllerGetTeam do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_02.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsBookingsControllerGetAllOrgTeamBookings do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_02.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsBookingsControllerGetBookingReferences do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_02.json", __MODULE__}
end

defmodule Operations.OrganizationsEventTypesPrivateLinksController20240904GetPrivateLinks do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_02.json", __MODULE__}
end
