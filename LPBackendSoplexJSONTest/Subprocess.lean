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
-/

import LPCore
import LPBackendSoplexJSON.Backend
import LPBackendSoplexJSON.Contract

open Soplex
open Soplex.Backend.SoplexJSON

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

def case_happyPath : IO Unit := withTempDir fun dir => do
  let bin := (dir / "fake-soplex").toString
  let body :=
    "{\"status\":\"optimal\",\"certificate\":" ++
    "{\"primal\":[\"3\"],\"dual\":[\"0\"]}}"
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
  let body :=
    "{\"status\":\"optimal\",\"certificate\":" ++
    "{\"primal\":[\"0\"],\"dual\":[\"0\"]}}"
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

def main : IO UInt32 := do
  if System.Platform.isWindows then
    IO.println "  [subprocess] skipped on Windows (uses sh/chmod)"
    return 0
  let cases : List (String × IO Unit) :=
    [ ("happyPath",                     case_happyPath),
      ("stdinReceivesEncodedRequest",   case_stdinReceivesEncodedRequest),
      ("nonZeroExitSurfacesStderr",     case_nonZeroExitSurfacesStderr),
      ("errorEnvelopeWinsOverNonZeroExit", case_errorEnvelopeWinsOverNonZeroExit),
      ("malformedJsonSurfaces",         case_malformedJsonSurfaces),
      ("spawnFailureIsActionable",      case_spawnFailureIsActionable),
      ("errorEnvelopeOnZeroExit",       case_errorEnvelopeOnZeroExit) ]
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
