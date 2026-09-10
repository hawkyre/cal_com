[
  import_deps: [:ecto, :typed_ecto_schema],
  # `scripts/` holds the two live certification sweeps: repo-only tooling, still
  # formatted and checked by CI like everything else the repository carries.
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,scripts}/**/*.{ex,exs}"]
]
