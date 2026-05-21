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
  "60fca2313ea3be14f578258dc6390f2fa07b26e7"

require LPTactic from git "https://github.com/kim-em/lp-tactic" @
  "eacb9b2270a9e9a810536f2c04e4f4ab7905dadf"

package LPBackendSoplexJSON

@[default_target]
lean_lib LPBackendSoplexJSON where
  roots := #[`LPBackendSoplexJSON]
  globs := #[`LPBackendSoplexJSON, `LPBackendSoplexJSON.Contract,
             `LPBackendSoplexJSON.Backend]
