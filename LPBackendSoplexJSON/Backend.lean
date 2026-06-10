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

module

public import LPCore
public import LPTactic.Registry
public import LPBackendSoplexJSON.Contract

@[expose] public section

namespace LP.Backend.SoplexJSON

open LP

/-- Resolve the SoPlex binary location. Honors
    `LP_BACKEND_SOPLEX_JSON_BIN` so users on a non-standard layout
    don't have to symlink. -/
def soplexBinary : IO String := do
  match (← IO.getEnv "LP_BACKEND_SOPLEX_JSON_BIN") with
  | some path => return path
  | none      => return "soplex"

/-- Run the SoPlex binary on a JSON-encoded `(opts, p)`, decode the
    response into a `Solution`.

    Spawns `bin` with `--solve --json`, writes the encoded request to
    stdin, reads the response from stdout. The wire-format
    `{ "error": ... }` envelope, a non-zero exit code, or a JSON-parse
    failure all surface through `SolveError.bridge` with an actionable
    diagnostic.

    The error envelope on stdout takes precedence over a non-zero exit
    code: a binary that crashes after writing `{ "error": ... }` still
    surfaces its diagnostic instead of a generic "exited with code N"
    message. -/
def solveExactWith (bin : String) {m n : Nat} (opts : Options) (p : Problem m n) :
    IO (Except SolveError (Solution m n)) := do
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
  -- Look for the documented error envelope on stdout first, regardless
  -- of exit code: a binary that crashes after writing diagnostics
  -- should still surface them.
  let decoded := decodeResponse m n out.stdout
  if out.exitCode ≠ 0 then
    match decoded with
    | .ok (.wireError msg) =>
      return .error <| SolveError.bridge s!"soplex-json: {msg}"
    | _ =>
      let stderrTail := out.stderr.trimAscii
      let stdoutHead :=
        let trimmed := out.stdout.trimAscii.copy
        if trimmed.utf8ByteSize ≤ 256 then trimmed
        else (trimmed.take 256).copy ++ "…"
      return .error <| SolveError.bridge
        s!"soplex-json: `{bin} --solve --json` exited with code \
           {out.exitCode}: stderr={stderrTail}; stdout={stdoutHead}"
  match decoded with
  | .error msg =>
    return .error <| SolveError.bridge
      s!"soplex-json: malformed response from `{bin}`: {msg}"
  | .ok (.wireError msg) =>
    return .error <| SolveError.bridge s!"soplex-json: {msg}"
  | .ok (.solution sol) =>
    return .ok sol

/-- The registry-facing entry point: resolves the binary from
    `LP_BACKEND_SOPLEX_JSON_BIN` (or `soplex` on `$PATH`) and defers
    to `solveExactWith`. Tests that need to spawn a fake binary can
    call `solveExactWith` directly. -/
def solveExact {m n : Nat} (opts : Options) (p : Problem m n) :
    IO (Except SolveError (Solution m n)) := do
  solveExactWith (← soplexBinary) opts p

/-- Probe `bin` end-to-end: send the trivial LP `minimize x, x ≥ 0`
    through `--solve --json` and require a decodable response (any
    status). A stock `soplex` binary fails here — it does not speak
    the JSON contract — which is exactly the diagnostic the registry
    should surface. Blocking semantics match the solve itself. -/
def probeWith (bin : String) : IO (Except String Unit) := do
  let probeProblem : Problem 0 1 :=
    { c := #v[1], a := #[], rowBounds := #v[], colBounds := #v[(some 0, none)] }
  match ← solveExactWith bin {} probeProblem with
  | .ok _ => return .ok ()
  | .error (.bridge msg) => return .error msg
  | .error e => return .error s!"probe solve failed: {repr e}"

/-- Registry-facing probe: `probeWith` against the resolved binary. -/
def probe : IO (Except String Unit) := do
  probeWith (← soplexBinary)

/-- The `LPBackend` value registered with the tactic registry. -/
def backend : LPBackend where
  name := "soplex-json"
  defaultPriority := 50
  solveExact := solveExact
  probe := probe

initialize registerBackend backend

end LP.Backend.SoplexJSON
