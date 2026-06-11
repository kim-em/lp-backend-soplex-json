/-
  Out-of-process SoPlex backend.

  Drives a contract-speaking binary through a JSON stdio protocol —
  see `Contract.lean` and `docs/json-contract.md`. The binary is
  resolved in priority order:

  1. `$LP_BACKEND_SOPLEX_JSON_BIN`, if set — the override for custom
     wrappers (a HiGHS harness, a Rust shim, etc.);
  2. otherwise the wrapper shipped in this package
     (`scripts/soplex-json-wrapper.py`), which drives a stock `soplex`
     CLI underneath. So `brew install soplex` + `import
     LPBackendSoplexJSON` gives a working `by lp` with no further
     configuration.

  The shipped wrapper is embedded at build time with `include_str`
  and materialized to a temp file at runtime, so resolution does not
  depend on where the package was checked out.

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

/-- The contract-speaking SoPlex wrapper, embedded at build time. It
    drives a stock `soplex` CLI underneath; see
    `scripts/soplex-json-wrapper.py`. -/
def bundledWrapperSource : String := include_str "../scripts/soplex-json-wrapper.py"

/-- The directory the bundled wrapper is materialized into. We prefer a
    user-private cache directory (`$XDG_CACHE_HOME`, then `$HOME/.cache`)
    over a shared system temp dir, so the materialized path is not a
    predictable location another local user could pre-seed. Falls back to
    `$TMPDIR` / `$TMP` / `/tmp` only when no home is available. -/
def wrapperCacheDir : IO System.FilePath := do
  let fromEnv (names : List String) : IO (Option System.FilePath) := do
    for name in names do
      if let some v ← IO.getEnv name then
        if !v.isEmpty then return some (System.FilePath.mk v)
    return none
  match ← fromEnv ["XDG_CACHE_HOME"] with
  | some c => return c / "lp-backend-soplex-json"
  | none =>
    match ← fromEnv ["HOME"] with
    | some h => return h / ".cache" / "lp-backend-soplex-json"
    | none =>
      let base := (← fromEnv ["TMPDIR", "TMP"]).getD (System.FilePath.mk "/tmp")
      return base / "lp-backend-soplex-json"

/-- Materialize the embedded wrapper to a content-addressed path and
    return it, ready to spawn. Idempotent: the filename embeds a hash
    of the source, so a present file is reused and a bumped wrapper
    never collides with a stale one. The script is written to a unique
    temp name and `rename`d into place, so a concurrent solve never
    observes a half-written file. -/
def bundledWrapperPath : IO String := do
  let dir ← wrapperCacheDir
  IO.FS.createDirAll dir
  let name := s!"soplex-json-wrapper-{bundledWrapperSource.hash}.py"
  let path := dir / name
  unless ← path.pathExists do
    let tmp := dir / s!"{name}.{(← IO.monoNanosNow)}.tmp"
    IO.FS.writeFile tmp bundledWrapperSource
    -- `chmod +x` so the `#!/usr/bin/env python3` shebang routes it.
    let chmod ← IO.Process.output { cmd := "chmod", args := #["+x", tmp.toString] }
    if chmod.exitCode ≠ 0 then
      throw (IO.userError s!"soplex-json: chmod failed on {tmp}: {chmod.stderr}")
    IO.FS.rename tmp path
  return path.toString

/-- Resolve the contract-speaking binary. `LP_BACKEND_SOPLEX_JSON_BIN`
    overrides everything (point it at a custom wrapper); otherwise the
    bundled wrapper is materialized and used. On Windows the bundled
    script cannot be marked executable, so we fall back to a bare
    `soplex` on `$PATH` — which does not speak the contract, so the
    probe reports it unavailable until the user sets the override. -/
def soplexBinary : IO String := do
  match (← IO.getEnv "LP_BACKEND_SOPLEX_JSON_BIN") with
  | some path => return path
  | none      =>
    if System.Platform.isWindows then return "soplex"
    else bundledWrapperPath

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
