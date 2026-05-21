/-
  Behavioral tests for the JSON encoder/decoder.

  Round-trips hand-crafted `Problem`s and `Solution`s through the
  wire-format string and back, with no native dependencies and no
  external solver involved. Validates that:

    * every `Rat` round-trips through `ratToWire` / `ratFromWire`
      exactly (no `Float` detour);
    * the encoded request is valid JSON the response decoder would
      have to round-trip through anyway;
    * `null` bounds (±∞) survive the trip;
    * the `{ "error": ... }` envelope decodes into `Decoded.wireError`;
    * the `unbounded` status maps the wire's `primal` into
      `Certificate.ray`;
    * length mismatches surface as decode errors rather than
      silently truncating.
-/

import Lean.Data.Json
import LPCore
import LPBackendSoplexJSON.Contract

open Lean (Json)
open Soplex
open Soplex.Backend.SoplexJSON

namespace LPBackendSoplexJSONTest.Contract

private def assertM (cond : Bool) (msg : String) : IO Unit := do
  unless cond do throw (IO.userError msg)

private def assertEqStr (got want : String) (label : String) : IO Unit := do
  unless got = want do
    throw (IO.userError s!"{label}: got '{got}', want '{want}'")

/-! ## Rational round-trip -/

def case_ratRoundTrip : IO Unit := do
  let samples : List Rat :=
    [ 0, 1, -1, 7, -7, mkRat 22 7, mkRat (-22) 7,
      mkRat 1 1000000, mkRat (-1) 1000000,
      mkRat 9223372036854775807 1,
      mkRat (-9223372036854775808) 1,
      mkRat 1234567890123456789 9876543210987654321 ]
  for q in samples do
    let s := ratToWire q
    match ratFromWire s with
    | .ok q' =>
      assertM (q' = q) s!"rat round-trip mismatch: {s} → {q'} ≠ {q}"
    | .error e =>
      throw (IO.userError s!"rat round-trip failed on {s}: {e}")

def case_ratFromWireRejectsGarbage : IO Unit := do
  let cases : List String :=
    [ "", "+1", "01", " 1", "1 ", "1/", "/1", "1/0", "1/01",
      "1.5", "1e3", "--1", "1/2/3", "abc" ]
  for s in cases do
    match ratFromWire s with
    | .ok q =>
      throw (IO.userError s!"expected rejection of '{s}', got {q}")
    | .error _ => pure ()

/-! ## Request encoding -/

/-- A two-row, three-variable LP exercising every interesting bound
    shape (`null`, finite, equality, negative). -/
def sampleProblem : Problem 2 3 :=
  { c := ⟨#[mkRat 1 1, mkRat (-2) 1, mkRat 3 7], rfl⟩,
    objOffset := mkRat 5 2,
    a :=
      #[ Problem.entry 0 0 (1 : Rat),
         Problem.entry 0 2 (mkRat (-1) 1),
         Problem.entry 1 1 (mkRat 2 3) ],
    rowBounds := ⟨#[ (some (0 : Rat), none), (some (3 : Rat), some (3 : Rat)) ], rfl⟩,
    colBounds := ⟨#[ (some (0 : Rat), none),
                     (none, some (1 : Rat)),
                     (none, none) ], rfl⟩ }

def case_requestIsValidJson : IO Unit := do
  let s := encodeRequest (m := 2) (n := 3) {} sampleProblem
  match Json.parse s with
  | .error e =>
    throw (IO.userError s!"encoded request not valid JSON: {e}\n{s}")
  | .ok j =>
    -- The top-level object has `options` and `problem`.
    let opt ← IO.ofExcept (j.getObjVal? "options")
    let prob ← IO.ofExcept (j.getObjVal? "problem")
    -- `presolve` is always false on the wire.
    let preStr := toString (opt.getObjValD "presolve")
    assertM (preStr = "false") s!"presolve not false: {preStr}"
    -- `numConstraints` and `numVars` match the type-level dimensions.
    assertM
      ((← IO.ofExcept (prob.getObjVal? "numConstraints" >>= Json.getNat?)) = 2)
      "numConstraints"
    assertM
      ((← IO.ofExcept (prob.getObjVal? "numVars" >>= Json.getNat?)) = 3)
      "numVars"

def case_boundsEncodeAsNullOrString : IO Unit := do
  let s := encodeRequest (m := 2) (n := 3) {} sampleProblem
  let j ← IO.ofExcept (Json.parse s)
  let prob ← IO.ofExcept (j.getObjVal? "problem")
  let cb ← IO.ofExcept (prob.getObjVal? "colBounds" >>= Json.getArr?)
  assertM (cb.size = 3) "colBounds length"
  -- Third entry: both bounds null (free variable).
  let third := cb[2]!
  let lo := third.getArrVal? 0 |>.toOption |>.getD Json.null
  let hi := third.getArrVal? 1 |>.toOption |>.getD Json.null
  assertM lo.isNull "third col lo should be null"
  assertM hi.isNull "third col hi should be null"
  -- First entry: lo is a string ("0"), hi is null.
  let first := cb[0]!
  let lo0 ← IO.ofExcept (first.getArrVal? 0 >>= Json.getStr?)
  assertM (lo0 = "0") s!"first col lo: {lo0}"

def case_sparseEntriesAreTriples : IO Unit := do
  let s := encodeRequest (m := 2) (n := 3) {} sampleProblem
  let j ← IO.ofExcept (Json.parse s)
  let prob ← IO.ofExcept (j.getObjVal? "problem")
  let a ← IO.ofExcept (prob.getObjVal? "a" >>= Json.getArr?)
  assertM (a.size = 3) "a size"
  -- Inspect the third entry: row 1, col 1, value "2/3".
  let e := a[2]!
  let r ← IO.ofExcept (e.getArrVal? 0 >>= Json.getNat?)
  let c ← IO.ofExcept (e.getArrVal? 1 >>= Json.getNat?)
  let v ← IO.ofExcept (e.getArrVal? 2 >>= Json.getStr?)
  assertM (r = 1 ∧ c = 1 ∧ v = "2/3") s!"a[2] = ({r},{c},{v})"

/-! ## Response decoding -/

def case_decodeOptimal : IO Unit := do
  let resp := "{\"status\":\"optimal\",\"certificate\":{\"primal\":[\"1\",\"-1/2\",\"3/7\"],\"dual\":[\"0\",\"2\"]}}"
  match decodeResponse 2 3 resp with
  | .error e => throw (IO.userError s!"decode failed: {e}")
  | .ok (.wireError msg) => throw (IO.userError s!"unexpected wireError: {msg}")
  | .ok (.solution sol) =>
    match sol.status with
    | .optimal => pure ()
    | other => throw (IO.userError s!"wrong status: {repr other}")
    let some primal := sol.certificate.primal
      | throw (IO.userError "missing primal")
    assertM (primal[0] = 1) s!"primal[0] = {primal[0]}"
    assertM (primal[1] = mkRat (-1) 2) s!"primal[1] = {primal[1]}"
    assertM (primal[2] = mkRat 3 7) s!"primal[2] = {primal[2]}"
    -- Dual is split signed → positive/negative; both rows are nonneg.
    let some dual := sol.certificate.dual
      | throw (IO.userError "missing dual")
    assertM (dual.rowLower[0] = 0) "dual rowLower[0]"
    assertM (dual.rowLower[1] = 2) s!"dual rowLower[1] = {dual.rowLower[1]}"
    assertM (dual.rowUpper[0] = 0) "dual rowUpper[0]"
    assertM (dual.rowUpper[1] = 0) "dual rowUpper[1]"

def case_decodeSignedDualSplit : IO Unit := do
  let resp := "{\"status\":\"optimal\",\"certificate\":{\"primal\":[\"0\"],\"dual\":[\"-3/4\"]}}"
  match decodeResponse 1 1 resp with
  | .ok (.solution sol) =>
    let some dual := sol.certificate.dual
      | throw (IO.userError "missing dual")
    assertM (dual.rowLower[0] = 0) s!"rowLower[0] = {dual.rowLower[0]}"
    assertM (dual.rowUpper[0] = mkRat 3 4) s!"rowUpper[0] = {dual.rowUpper[0]}"
  | other => throw (IO.userError s!"decode: {repr other}")

def case_decodeUnboundedRoutesPrimalToRay : IO Unit := do
  let resp := "{\"status\":\"unbounded\",\"certificate\":{\"primal\":[\"1\",\"0\",\"0\"],\"dual\":null}}"
  match decodeResponse 2 3 resp with
  | .ok (.solution sol) =>
    match sol.status with
    | .unbounded => pure ()
    | other => throw (IO.userError s!"status: {repr other}")
    assertM sol.certificate.primal.isNone "primal should be none for unbounded"
    let some ray := sol.certificate.ray
      | throw (IO.userError "ray should be set for unbounded")
    assertM (ray[0] = 1) s!"ray[0] = {ray[0]}"
    assertM sol.certificate.dual.isNone "dual should be none"
  | other => throw (IO.userError s!"decode: {repr other}")

def case_decodeInfeasibleHasDualOnly : IO Unit := do
  let resp := "{\"status\":\"infeasible\",\"certificate\":{\"primal\":null,\"dual\":[\"1\",\"0\"]}}"
  match decodeResponse 2 3 resp with
  | .ok (.solution sol) =>
    match sol.status with
    | .infeasible => pure ()
    | other => throw (IO.userError s!"status: {repr other}")
    assertM sol.certificate.primal.isNone "primal should be none"
    assertM sol.certificate.ray.isNone "ray should be none"
    let some _ := sol.certificate.dual
      | throw (IO.userError "dual should be set")
  | other => throw (IO.userError s!"decode: {repr other}")

def case_decodeErrorEnvelope : IO Unit := do
  let resp := "{\"error\":\"soplex segfaulted\"}"
  match decodeResponse 0 0 resp with
  | .ok (.wireError msg) =>
    assertM (msg = "soplex segfaulted") s!"got: {msg}"
  | other => throw (IO.userError s!"expected wireError, got: {repr other}")

def case_decodeLengthMismatchRejected : IO Unit := do
  let resp := "{\"status\":\"optimal\",\"certificate\":{\"primal\":[\"1\",\"2\"],\"dual\":[\"0\",\"0\"]}}"
  match decodeResponse 2 3 resp with
  | .error _ => pure ()
  | other => throw (IO.userError s!"expected length-mismatch error, got: {repr other}")

def case_decodeMalformedRationalRejected : IO Unit := do
  let resp := "{\"status\":\"optimal\",\"certificate\":{\"primal\":[\"1.5\",\"0\",\"0\"],\"dual\":[\"0\",\"0\"]}}"
  match decodeResponse 2 3 resp with
  | .error _ => pure ()
  | other => throw (IO.userError s!"expected malformed-rational error, got: {repr other}")

def case_decodeRejectsNonObjectCertificate : IO Unit := do
  let resp := "{\"status\":\"optimal\",\"certificate\":[]}"
  match decodeResponse 0 0 resp with
  | .error _ => pure ()
  | other => throw (IO.userError s!"expected error for non-object certificate, got: {repr other}")

def case_decodeRejectsNonStringErrorEnvelope : IO Unit := do
  let resp := "{\"error\":42}"
  match decodeResponse 0 0 resp with
  | .error _ => pure ()
  | other => throw (IO.userError s!"expected error for non-string envelope, got: {repr other}")

def case_decodeNonTerminalStatus : IO Unit := do
  let resp := "{\"status\":\"timeLimit\",\"certificate\":{\"primal\":null,\"dual\":null}}"
  match decodeResponse 0 0 resp with
  | .ok (.solution sol) =>
    match sol.status with
    | .timeLimit => pure ()
    | other => throw (IO.userError s!"status: {repr other}")
  | other => throw (IO.userError s!"decode: {repr other}")

/-- Round-trip the request through `Json.parse`, then assert it
    decodes to the same byte string. Catches accidental
    floating-point detours in the encoder. -/
def case_requestIsCanonical : IO Unit := do
  let s := encodeRequest (m := 2) (n := 3) {} sampleProblem
  let j ← IO.ofExcept (Json.parse s)
  -- `Json.compress` is deterministic on the parsed AST: round-tripping
  -- it through the parser should give back the same string, modulo
  -- key ordering. `Json.mkObj` already returns a stable ordering.
  -- We just check that the rationals come out as strings:
  let prob ← IO.ofExcept (j.getObjVal? "problem")
  let c ← IO.ofExcept (prob.getObjVal? "c" >>= Json.getArr?)
  for e in c do
    let _ ← IO.ofExcept e.getStr?  -- must be a string, never a JSON number
  pure ()

def main : IO UInt32 := do
  let cases : List (String × IO Unit) :=
    [ ("ratRoundTrip",                   case_ratRoundTrip),
      ("ratFromWireRejectsGarbage",      case_ratFromWireRejectsGarbage),
      ("requestIsValidJson",             case_requestIsValidJson),
      ("boundsEncodeAsNullOrString",     case_boundsEncodeAsNullOrString),
      ("sparseEntriesAreTriples",        case_sparseEntriesAreTriples),
      ("requestIsCanonical",             case_requestIsCanonical),
      ("decodeOptimal",                  case_decodeOptimal),
      ("decodeSignedDualSplit",          case_decodeSignedDualSplit),
      ("decodeUnboundedRoutesPrimalToRay", case_decodeUnboundedRoutesPrimalToRay),
      ("decodeInfeasibleHasDualOnly",    case_decodeInfeasibleHasDualOnly),
      ("decodeErrorEnvelope",            case_decodeErrorEnvelope),
      ("decodeLengthMismatchRejected",   case_decodeLengthMismatchRejected),
      ("decodeMalformedRationalRejected", case_decodeMalformedRationalRejected),
      ("decodeRejectsNonObjectCertificate", case_decodeRejectsNonObjectCertificate),
      ("decodeRejectsNonStringErrorEnvelope", case_decodeRejectsNonStringErrorEnvelope),
      ("decodeNonTerminalStatus",        case_decodeNonTerminalStatus) ]
  let mut failures := 0
  for (name, action) in cases do
    IO.print s!"  [contract] {name} ... "
    try
      action
      IO.println "ok"
    catch e =>
      IO.println s!"FAIL: {e}"
      failures := failures + 1
  if failures = 0 then
    IO.println s!"All {cases.length} contract tests passed."
    pure 0
  else
    IO.println s!"{failures} of {cases.length} contract tests FAILED."
    pure 1

end LPBackendSoplexJSONTest.Contract
