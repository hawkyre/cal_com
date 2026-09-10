alias CalCom.Operations

defmodule Operations.OrganizationsMembershipsControllerDeleteMembership do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_06.json", __MODULE__}
end

defmodule Operations.OrganizationsMembershipsControllerUpdateMembership do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_06.json", __MODULE__}
end

defmodule Operations.OrganizationsRolesControllerCreateRole do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_06.json", __MODULE__}
end

defmodule Operations.OrganizationsRolesControllerGetAllRoles do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_06.json", __MODULE__}
end

defmodule Operations.OrganizationsRolesControllerGetRole do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_06.json", __MODULE__}
end
