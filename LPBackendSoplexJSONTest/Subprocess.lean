/-
  Subprocess-level tests for `solveExactWith`.

  Drives a hand-written `sh` shim that captures stdin and replies
  with a controlled stdout / stderr / exit code. Tests the
  end-to-end IO path:

    * binary spawning and stdin/stdout pipes;
    * stderr capture on non-zero exit;
    * the documented `{ "error": ... }` envelope on stdout takes
      precedence over a non-zero exit code (so a binary that
      crashes after writing diagnostics still surfaces them);
    * malformed stdout produces a structured `bridge` error;
    * the request bytes the binary sees match `encodeRequest`.

  Unix-only (uses `sh` and `chmod`). Skipped on Windows.

  The final block drives the *real* shipped wrapper
  (`scripts/soplex-json-wrapper.py`) against an installed `soplex`,
  and runs every certificate it produces back through the Lean
  verifier (`verifyOutcome`) — the same end-to-end conformance the
  registry probe checks. These cases are skipped when no `soplex` is
  on `$PATH`; CI installs one so they run.
-/

import LPCore
import LPVerify
import LPBackendSoplexJSON.Backend
import LPBackendSoplexJSON.Contract

open LP
open LP.Backend.SoplexJSON

namespace LPBackendSoplexJSONTest.Subprocess

private def assertM (cond : Bool) (msg : String) : IO Unit := do
  unless cond do throw (IO.userError msg)

/-- Tiny problem used to drive `solveExactWith`. Dimensions chosen
    so the fake responses are short to write out. -/
private def tinyProblem : Problem 1 1 :=
  { c := ⟨#[(1 : Rat)], rfl⟩,
    a := #[ Problem.entry 0 0 (1 : Rat) ],
    rowBounds := ⟨#[ (some (0 : Rat), none) ], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none) ], rfl⟩ }

/-- Write `content` to `path`, then `chmod +x` it via a subshell.
    Used to materialise a one-shot `sh` shim for one test case. -/
private def writeExecutable (path : System.FilePath) (content : String) :
    IO Unit := do
  IO.FS.writeFile path content
  let out ← IO.Process.output { cmd := "chmod", args := #["+x", path.toString] }
  if out.exitCode ≠ 0 then
    throw (IO.userError s!"chmod failed: {out.stderr}")

/-- Run `action` with a freshly-created temp directory, removing the
    directory afterwards even if `action` throws. -/
private def withTempDir (action : System.FilePath → IO α) : IO α := do
  let base := (← IO.appDir) / ".test-tmp"
  IO.FS.createDirAll base
  let dir := base / s!"sub-{(← IO.monoMsNow)}"
  IO.FS.createDirAll dir
  try
    let r ← action dir
    IO.FS.removeDirAll dir
    pure r
  catch e =>
    try IO.FS.removeDirAll dir catch _ => pure ()
    throw e

/-- A `sh` shim that ignores stdin, prints the supplied body to
    stdout, and exits with the supplied code. -/
private def shimScript (stdoutBody : String) (exitCode : Nat := 0)
    (stderrBody : String := "") : String :=
  -- We read and discard stdin so the backend's `Stdio.piped` write
  -- doesn't hit a broken pipe.
  let stderrLine :=
    if stderrBody.isEmpty then ""
    else s!"printf '%s' '{stderrBody}' >&2\n"
  s!"#!/bin/sh\ncat > /dev/null\n{stderrLine}printf '%s' '{stdoutBody}'\nexit {exitCode}\n"

/-- A shim that captures the request bytes to a side file. Used to
    assert that the wire request `encodeRequest` produces is what
    actually reaches the binary's stdin. -/
private def captureShim (capturePath : String) (stdoutBody : String) : String :=
  s!"#!/bin/sh\ncat > '{capturePath}'\nprintf '%s' '{stdoutBody}'\nexit 0\n"

/-- A 1×1 optimal response in the four-vector dual form. -/
private def optimalBody (primal : String) : String :=
  "{\"status\":\"optimal\",\"certificate\":{\"primal\":[\"" ++ primal ++ "\"],\"ray\":null,\"dual\":" ++
  "{\"rowLower\":[\"0\"],\"rowUpper\":[\"0\"],\"colLower\":[\"0\"],\"colUpper\":[\"0\"]}}}"

def case_happyPath : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  let body := optimalBody "3"
  writeExecutable ⟨bin⟩ (shimScript body)
  match (← solveExactWith bin (m := 1) (n := 1) {} tinyProblem) with
  | .ok sol =>
    match sol.status with
    | .optimal => pure ()
    | other => throw (IO.userError s!"status: {repr other}")
    let some primal := sol.certificate.primal
      | throw (IO.userError "missing primal")
    assertM (primal[0] = (3 : Rat)) s!"primal[0]={primal[0]}"
  | .error e => throw (IO.userError s!"unexpected error: {repr e}")

def case_stdinReceivesEncodedRequest : IO Unit := withTempDir fun dir => do
  let captured := (dir / "captured.json").toString
  let bin      := (dir / "fake-soplex").toString
  let body := optimalBody "0"
  writeExecutable ⟨bin⟩ (captureShim captured body)
  let _ ← solveExactWith bin (m := 1) (n := 1) {} tinyProblem
  let onWire ← IO.FS.readFile captured
  let expected := encodeRequest (m := 1) (n := 1) {} tinyProblem
  assertM (onWire = expected) s!"stdin mismatch:\ngot: {onWire}\nwant: {expected}"

def case_nonZeroExitSurfacesStderr : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  writeExecutable ⟨bin⟩ (shimScript "" 7 "boom: licence expired")
  match (← solveExactWith bin (m := 1) (n := 1) {} tinyProblem) with
  | .error (.bridge msg) =>
    assertM ((msg.splitOn "exited with code 7").length > 1)
      s!"missing exit code in: {msg}"
    assertM ((msg.splitOn "boom: licence expired").length > 1)
      s!"missing stderr in: {msg}"
  | other => throw (IO.userError s!"expected bridge error, got: {repr other}")

def case_errorEnvelopeWinsOverNonZeroExit : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  let body := "{\"error\":\"refinement failed\"}"
  -- Solver exits non-zero AND writes the envelope. The envelope must
  -- be surfaced verbatim, not the generic "exited with code N" diag.
  writeExecutable ⟨bin⟩ (shimScript body 1 "noise on stderr")
  match (← solveExactWith bin (m := 1) (n := 1) {} tinyProblem) with
  | .error (.bridge msg) =>
    assertM ((msg.splitOn "refinement failed").length > 1)
      s!"envelope diag missing from: {msg}"
    assertM ((msg.splitOn "exited with code").length = 1)
      s!"generic exit-code text leaked into: {msg}"
  | other => throw (IO.userError s!"expected bridge error, got: {repr other}")

def case_malformedJsonSurfaces : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  writeExecutable ⟨bin⟩ (shimScript "not json at all" 0)
  match (← solveExactWith bin (m := 1) (n := 1) {} tinyProblem) with
  | .error (.bridge msg) =>
    assertM ((msg.splitOn "malformed response").length > 1)
      s!"missing 'malformed response' tag in: {msg}"
  | other => throw (IO.userError s!"expected bridge error, got: {repr other}")

def case_spawnFailureIsActionable : IO Unit := do
  -- Whether `IO.Process.output` throws or returns a non-zero exit on
  -- a missing binary varies across platforms; either path must
  -- produce an actionable bridge error naming the path.
  let bogus := "/nonexistent/path/to/no-such-soplex"
  match (← solveExactWith bogus (m := 1) (n := 1) {} tinyProblem) with
  | .error (.bridge msg) =>
    assertM ((msg.splitOn bogus).length > 1)
      s!"bridge diag should name the binary, got: {msg}"
  | other => throw (IO.userError s!"expected bridge error, got: {repr other}")

def case_errorEnvelopeOnZeroExit : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  writeExecutable ⟨bin⟩ (shimScript "{\"error\":\"out of memory\"}" 0)
  match (← solveExactWith bin (m := 1) (n := 1) {} tinyProblem) with
  | .error (.bridge msg) =>
    assertM ((msg.splitOn "out of memory").length > 1)
      s!"missing envelope diag in: {msg}"
  | other => throw (IO.userError s!"expected bridge error, got: {repr other}")

/-- `probeWith` accepts a contract-speaking binary (any decodable
    response counts)... -/
def case_probeAcceptsContractSpeaker : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  -- The probe problem is 0×1; answer it with a decodable response.
  let body :=
    "{\"status\":\"optimal\",\"certificate\":{\"primal\":[\"0\"],\"ray\":null,\"dual\":" ++
    "{\"rowLower\":[],\"rowUpper\":[],\"colLower\":[\"1\"],\"colUpper\":[\"0\"]}}}"
  writeExecutable ⟨bin⟩ (shimScript body)
  match ← probeWith bin with
  | .ok () => pure ()
  | .error e => throw (IO.userError s!"probe rejected contract speaker: {e}")

/-- ...and rejects a binary that answers with non-contract output,
    the way a stock `soplex` CLI would. -/
def case_probeRejectsNonContractBinary : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  writeExecutable ⟨bin⟩ (shimScript "SoPlex usage: soplex [options] <lpfile>" 1)
  match ← probeWith bin with
  | .error _ => pure ()
  | .ok () => throw (IO.userError "probe accepted a non-contract binary")

/-! ## Real-wrapper integration tests.

    These drive the shipped `scripts/soplex-json-wrapper.py` against an
    installed `soplex`, then run the certificate it returns back
    through the verifier. They are skipped when `soplex` is absent. -/

/-- Is a stock `soplex` CLI on `$PATH`? (`--version` exits 0; a spawn
    failure means it is not installed.) -/
private def soplexAvailable : IO Bool := do
  try
    let out ← IO.Process.output { cmd := "soplex", args := #["--version"] }
    return out.exitCode == 0
  catch _ => return false

/-- Solve `p` (sense from `opts`) through the bundled wrapper and assert
    the verifier accepts the certificate via the `expected` constructor
    check on the resulting `Verified` value. -/
private def verifyVia {m n : Nat} (opts : Options) (p : Problem m n)
    (label : String) (expected : LP.Verify.Verified p opts.sense → Bool) :
    IO Unit := do
  let bin ← bundledWrapperPath
  match (← solveExactWith bin opts p) with
  | .error e => throw (IO.userError s!"{label}: wrapper error: {repr e}")
  | .ok sol =>
    let v := LP.Verify.verifyOutcome opts none p sol
    unless expected v do
      throw (IO.userError s!"{label}: verifier rejected the wrapper certificate \
                             (status {repr sol.status})")

/-- `minimize x₀` s.t. `x₀ ≥ 3` and `x₀ ≥ 0`: optimum `x₀ = 3`. -/
private def optProblem : Problem 1 1 :=
  { c := ⟨#[(1 : Rat)], rfl⟩,
    a := #[ Problem.entry 0 0 (1 : Rat) ],
    rowBounds := ⟨#[ (some (3 : Rat), none) ], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none) ], rfl⟩ }

/-- `x₀ ≤ -1` with `x₀ ≥ 0`: infeasible (Farkas certificate). -/
private def infProblem : Problem 1 1 :=
  { c := ⟨#[(1 : Rat)], rfl⟩,
    a := #[ Problem.entry 0 0 (1 : Rat) ],
    rowBounds := ⟨#[ (none, some (-1 : Rat)) ], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none) ], rfl⟩ }

/-- `minimize -x₀` s.t. `x₀ ≥ 0`: unbounded below (base point + ray). -/
private def unbProblem : Problem 0 1 :=
  { c := ⟨#[(-1 : Rat)], rfl⟩,
    a := #[],
    rowBounds := ⟨#[], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none) ], rfl⟩ }

/-- `maximize x₀` s.t. `0 ≤ x₀ ≤ 5`: optimum `x₀ = 5`. Exercises the
    sense-canonicalization path (the wrapper negates the objective). -/
private def maxProblem : Problem 0 1 :=
  { c := ⟨#[(1 : Rat)], rfl⟩,
    a := #[],
    rowBounds := ⟨#[], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), some (5 : Rat)) ], rfl⟩ }

/-- `minimize x₀ + (3/7)·x₁` s.t. `(2/7)·x₀ ≥ 5/11`, both `≥ 0`:
    a fractional optimum that catches any float detour end-to-end. -/
private def fracProblem : Problem 1 2 :=
  { c := ⟨#[(1 : Rat), mkRat 3 7], rfl⟩,
    a := #[ Problem.entry 0 0 (mkRat 2 7) ],
    rowBounds := ⟨#[ (some (mkRat 5 11), none) ], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none), (some (0 : Rat), none) ], rfl⟩ }

/-- `minimize x₀ + x₁` s.t. `x₀ + x₁ = 4`, `x₀ ≥ 0`, `x₁` free:
    exercises the equality-row (`=`) and free-variable (`x free`)
    emission branches. -/
private def eqFreeProblem : Problem 1 2 :=
  { c := ⟨#[(1 : Rat), (1 : Rat)], rfl⟩,
    a := #[ Problem.entry 0 0 (1 : Rat), Problem.entry 0 1 (1 : Rat) ],
    rowBounds := ⟨#[ (some (4 : Rat), some (4 : Rat)) ], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none), (none, none) ], rfl⟩ }

/-- `minimize x₀ + x₁` s.t. `x₀ + x₁ ≥ -5`, `-3 ≤ x₀ ≤ 4`, `x₁ ≤ 2`:
    exercises the negative-lower-bound and `-infinity ≤ x ≤ hi`
    emission branches. -/
private def negBoundProblem : Problem 1 2 :=
  { c := ⟨#[(1 : Rat), (1 : Rat)], rfl⟩,
    a := #[ Problem.entry 0 0 (1 : Rat), Problem.entry 0 1 (1 : Rat) ],
    rowBounds := ⟨#[ (some (-5 : Rat), none) ], rfl⟩,
    colBounds := ⟨#[ (some (-3 : Rat), some (4 : Rat)), (none, some (2 : Rat)) ], rfl⟩ }

def case_realOptimalVerifies : IO Unit :=
  verifyVia {} optProblem "realOptimal" fun
    | .optimal .. => true
    | _ => false

def case_realProbeVerifies : IO Unit :=
  -- The 0×1 probe LP itself, end-to-end through the verifier.
  let probeP : Problem 0 1 :=
    { c := #v[1], a := #[], rowBounds := #v[], colBounds := #v[(some 0, none)] }
  verifyVia {} probeP "realProbe" fun
    | .optimal .. => true
    | _ => false

def case_realInfeasibleVerifies : IO Unit :=
  verifyVia {} infProblem "realInfeasible" fun
    | .infeasible .. => true
    | _ => false

def case_realUnboundedVerifies : IO Unit :=
  verifyVia {} unbProblem "realUnbounded" fun
    | .unbounded .. => true
    | _ => false

def case_realMaximizeVerifies : IO Unit :=
  verifyVia { sense := .maximize } maxProblem "realMaximize" fun
    | .optimal .. => true
    | _ => false

def case_realFractionalVerifies : IO Unit :=
  verifyVia {} fracProblem "realFractional" fun
    | .optimal .. => true
    | _ => false

def case_realEqFreeVerifies : IO Unit :=
  verifyVia {} eqFreeProblem "realEqFree" fun
    | .optimal .. => true
    | _ => false

def case_realNegBoundVerifies : IO Unit :=
  verifyVia {} negBoundProblem "realNegBound" fun
    | .optimal .. => true
    | _ => false

/-- The shipped probe (`probe`) succeeds out of the box: with no env
    override set, it resolves the bundled wrapper and the trivial solve
    round-trips. -/
def case_shippedProbeSucceeds : IO Unit := do
  -- Clear any override so we exercise the bundled-wrapper fallback.
  match ← probeWith (← bundledWrapperPath) with
  | .ok () => pure ()
  | .error e => throw (IO.userError s!"shipped wrapper failed its own probe: {e}")

def main : IO UInt32 := do
  if System.Platform.isWindows then
    IO.println "  [subprocess] skipped on Windows (uses sh/chmod)"
    return 0
  let shimCases : List (String × IO Unit) :=
    [ ("happyPath",                     case_happyPath),
      ("stdinReceivesEncodedRequest",   case_stdinReceivesEncodedRequest),
      ("nonZeroExitSurfacesStderr",     case_nonZeroExitSurfacesStderr),
      ("errorEnvelopeWinsOverNonZeroExit", case_errorEnvelopeWinsOverNonZeroExit),
      ("malformedJsonSurfaces",         case_malformedJsonSurfaces),
      ("spawnFailureIsActionable",      case_spawnFailureIsActionable),
      ("errorEnvelopeOnZeroExit",       case_errorEnvelopeOnZeroExit),
      ("probeAcceptsContractSpeaker",   case_probeAcceptsContractSpeaker),
      ("probeRejectsNonContractBinary", case_probeRejectsNonContractBinary) ]
  let realCases : List (String × IO Unit) :=
    [ ("realProbeVerifies",             case_realProbeVerifies),
      ("shippedProbeSucceeds",          case_shippedProbeSucceeds),
      ("realOptimalVerifies",           case_realOptimalVerifies),
      ("realFractionalVerifies",        case_realFractionalVerifies),
      ("realEqFreeVerifies",            case_realEqFreeVerifies),
      ("realNegBoundVerifies",          case_realNegBoundVerifies),
      ("realInfeasibleVerifies",        case_realInfeasibleVerifies),
      ("realUnboundedVerifies",         case_realUnboundedVerifies),
      ("realMaximizeVerifies",          case_realMaximizeVerifies) ]
  let avail ← soplexAvailable
  unless avail do
    IO.println "  [subprocess] soplex not on PATH; skipping real-wrapper cases"
  let cases := if avail then shimCases ++ realCases else shimCases
  let mut failures := 0
  for (name, action) in cases do
    IO.print s!"  [subprocess] {name} ... "
    try
      action
      IO.println "ok"
    catch e =>
      IO.println s!"FAIL: {e}"
      failures := failures + 1
  if failures = 0 then
    IO.println s!"All {cases.length} subprocess tests passed."
    pure 0
  else
    IO.println s!"{failures} of {cases.length} subprocess tests FAILED."
    pure 1

end LPBackendSoplexJSONTest.Subprocess
