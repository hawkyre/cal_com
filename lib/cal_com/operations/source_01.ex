alias CalCom.Operations

defmodule Operations.OrganizationsRolesPermissionsControllerListPermissions do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_01.json", __MODULE__}
end

defmodule Operations.OrganizationsRoutingFormsControllerGetOrganizationRoutingForms do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_01.json", __MODULE__}
end

defmodule Operations.OrganizationsRoutingFormsResponsesControllerGetRoutingFormResponses do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_01.json", __MODULE__}
end

defmodule Operations.OrganizationsSchedulesControllerGetOrganizationSchedules do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_01.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsControllerGetAllTeams do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_01.json", __MODULE__}
end
