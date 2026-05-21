/-
  Out-of-process SoPlex backend.

  Drives an external `soplex` binary on `$PATH` (or a user-supplied
  absolute path via env var `LP_BACKEND_SOPLEX_JSON_BIN`) through a
  JSON stdio protocol — see `Contract.lean` and
  `docs/json-contract.md`.

  Self-registers under priority 50 ("subprocess band") on import:
  any consumer who `import LPBackendSoplexJSON` gets this in their
  `availableBackends` list. With the FFI backend (priority 10) also
  imported, the FFI is preferred by `dispatchSolveExact` because it
  has lower priority. With only this one imported, this becomes the
  default.

  The current implementation ships a working `probe` and a placeholder
  `solveExact` that returns a structured error. The wire-format
  encoder/decoder lives in `Contract.lean` and a follow-up will
  connect them. Importing this module is already useful today: it
  registers the backend so `availableBackends` lists it, and
  `set_option lp.backend "soplex-json"` switches dispatch to it.
-/

import LPCore
import LPTactic.Registry
import LPBackendSoplexJSON.Contract

namespace Soplex.Backend.SoplexJSON

open Soplex Soplex.LP

/-- Resolve the SoPlex binary location. Honors
    `LP_BACKEND_SOPLEX_JSON_BIN` so users on a non-standard layout
    don't have to symlink. -/
def soplexBinary : IO String := do
  match (← IO.getEnv "LP_BACKEND_SOPLEX_JSON_BIN") with
  | some path => return path
  | none      => return "soplex"

/-- Spawn `soplex --version`, capture the exit code. Returns `.ok ()`
    on success; on failure, a structured error naming the binary
    that was tried so the diagnostic is actionable. -/
def probe : IO (Except String Unit) := do
  let bin ← soplexBinary
  try
    let out ← IO.Process.output { cmd := bin, args := #["--version"] }
    if out.exitCode = 0 then
      return .ok ()
    else
      return .error
        s!"`{bin} --version` exited with code {out.exitCode}: {out.stderr.trimAscii}"
  catch e =>
    return .error
      s!"could not spawn `{bin} --version`: {e.toString} \
         (override with the `LP_BACKEND_SOPLEX_JSON_BIN` env var)"

/-- Run the SoPlex binary on a JSON-encoded `(opts, p)`, decode the
    response into a `Solution`.

    TODO: the encoder/decoder still need to land; see
    `Contract.lean` for the wire shape and `docs/json-contract.md`
    for the full spec. Until then the backend self-registers (so
    `availableBackends` lists it) but reports a structured "not yet
    wired" error from `solveExact`. -/
def solveExact {m n : Nat} (_opts : Options) (_p : Problem m n) :
    IO (Except SolveError (Solution m n)) := do
  return Except.error
    (SolveError.bridge
      "soplex-json backend: JSON encoder/decoder not yet implemented; \
       see kim-em/lp-backend-soplex-json `docs/json-contract.md`")

/-- The `LPBackend` value registered with the tactic registry. -/
def backend : LPBackend where
  name := "soplex-json"
  defaultPriority := 50
  solveExact := solveExact
  probe := probe

initialize registerBackend backend

end Soplex.Backend.SoplexJSON
