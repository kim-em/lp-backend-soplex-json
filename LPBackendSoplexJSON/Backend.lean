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

    Spawns `$LP_BACKEND_SOPLEX_JSON_BIN` (or `soplex` on `$PATH`) with
    `--solve --json`, writes the encoded request to stdin, reads the
    response from stdout. The wire-format `{ "error": ... }` envelope,
    a non-zero exit code, or a JSON-parse failure all surface through
    `SolveError.bridge` with an actionable diagnostic. -/
def solveExact {m n : Nat} (opts : Options) (p : Problem m n) :
    IO (Except SolveError (Solution m n)) := do
  let bin ← soplexBinary
  let request := encodeRequest opts p
  let out ← try
    IO.Process.output
      { cmd    := bin,
        args   := #["--solve", "--json"],
        stdin  := .piped,
        stdout := .piped,
        stderr := .piped } request
  catch e =>
    return .error <| SolveError.bridge
      s!"soplex-json: could not spawn `{bin} --solve --json`: {e.toString} \
         (override with the `LP_BACKEND_SOPLEX_JSON_BIN` env var)"
  if out.exitCode ≠ 0 then
    return .error <| SolveError.bridge
      s!"soplex-json: `{bin} --solve --json` exited with code {out.exitCode}: \
         {out.stderr.trimAscii}"
  match decodeResponse m n out.stdout with
  | .error msg =>
    return .error <| SolveError.bridge
      s!"soplex-json: malformed response from `{bin}`: {msg}"
  | .ok (.wireError msg) =>
    return .error <| SolveError.bridge s!"soplex-json: {msg}"
  | .ok (.solution sol) =>
    return .ok sol

/-- The `LPBackend` value registered with the tactic registry. -/
def backend : LPBackend where
  name := "soplex-json"
  defaultPriority := 50
  solveExact := solveExact
  probe := probe

initialize registerBackend backend

end Soplex.Backend.SoplexJSON
