/-
  Top-level entry point for `LPBackendSoplexJSON`.

  Self-registers the JSON subprocess backend with the `lp-tactic`
  registry on import.
-/
module

public import LPBackendSoplexJSON.Backend

@[expose] public section
