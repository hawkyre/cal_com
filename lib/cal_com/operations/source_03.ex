alias CalCom.Operations

defmodule Operations.OrganizationsAttributesOptionsControllerGetOrganizationAttributeAssignmentHistory do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationAttributeSyncHistoryControllerGetAttributeSyncHistory do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationAttributeSyncHistoryControllerGetUserSyncHistory do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationsBookingsControllerGetAllOrgTeamBookingsCursor do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationsBookingsControllerReportOrgBooking do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end
