defmodule CalCom.Test.Patch do
  @moduledoc "A synthetic schema used to test presence semantics, compiled before protocol consolidation."
  alias CalCom.Rule

  use CalCom.Schema,
    fields: [
      {:title, "title", %Rule{kind: :string, nullable: true}, String.t(), false},
      {:enabled, "enabled", %Rule{kind: :boolean}, boolean(), false},
      {:count, "count", %Rule{kind: :integer}, integer(), false},
      {:items, "items", %Rule{kind: {:array, %Rule{kind: :integer}}}, [integer()], false}
    ],
    additional: false
end
