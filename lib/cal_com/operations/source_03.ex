alias CalCom.Operations

defmodule Operations.OrganizationsTeamsMembershipsControllerGetAllOrgTeamMemberships do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsMembershipsControllerGetOrgTeamMembership do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsRolesControllerGetAllRoles do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsRolesControllerGetRole do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end

defmodule Operations.OrganizationsTeamsRolesPermissionsControllerListPermissions do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_03.json", __MODULE__}
end
