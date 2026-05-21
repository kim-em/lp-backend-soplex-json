import Lake
open Lake DSL

/-! # `LPBackendSoplexJSON` build configuration

  Out-of-process SoPlex backend: drives a `soplex` (or compatible)
  binary on `$PATH` via a JSON stdio protocol. Self-registers with
  the `lp-tactic` registry under priority 50 ("subprocess band")
  on import.

  **No native deps in the build graph.** SoPlex enters the picture
  at *runtime* — when `solveExact` is called, the backend spawns
  the external binary. The user installs it however they want
  (`brew install soplex`, an apt package, a hand-built binary on
  the PATH) instead of rebuilding it through Lake every time.

  See `docs/json-contract.md` for the wire protocol. Any external
  tool that emits the same JSON shape (a Python harness driving
  HiGHS, a Rust shim, etc.) can serve as a drop-in backend.
-/

require LPCore from git "https://github.com/kim-em/lp-core" @
  "98669eee0fe05bcc1ed9aa2c7c7adff5d1aaf9ae"

require LPTactic from git "https://github.com/kim-em/lp-tactic" @
  "3ab98a31eb89bc4eca00442cd58249490822ac3c"

package LPBackendSoplexJSON

@[default_target]
lean_lib LPBackendSoplexJSON where
  roots := #[`LPBackendSoplexJSON]
  globs := #[`LPBackendSoplexJSON, `LPBackendSoplexJSON.Contract,
             `LPBackendSoplexJSON.Backend]
