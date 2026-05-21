/-
  JSON wire-format contract for the out-of-process SoPlex backend.

  Wire shape (request, stdin):
  ```json
  {
    "options": { "sense": "minimize", "presolve": false, ... },
    "problem": {
      "numConstraints": <Nat>,
      "numVars": <Nat>,
      "c": ["<Rat>", ...],
      "objOffset": "<Rat>",
      "a": [[<row>, <col>, "<Rat>"], ...],
      "rowBounds": [[<lo|null>, <hi|null>], ...],
      "colBounds": [[<lo|null>, <hi|null>], ...]
    }
  }
  ```

  Wire shape (response, stdout):
  ```json
  {
    "status": "optimal" | "infeasible" | "unbounded" | "timeLimit" | ...,
    "certificate": {
      "primal": ["<Rat>", ...] | null,
      "dual":   ["<Rat>", ...] | null
    }
  }
  ```

  All rational numbers travel as decimal strings (`"3/7"`, `"-1"`),
  *not* as JSON numbers — IEEE 754 floats would round the kernel-
  checked exact rationals that the verifier downstream consumes.

  See `docs/json-contract.md` for the full spec including the
  precedence rules and recoverable-error subset (so a JSON backend
  written in Python / Rust / anything stays interop-stable with the
  Lean side).
-/

import Lean.Data.Json
import LPCore.Types

namespace Soplex.Backend.SoplexJSON

open Lean (Json)
open Soplex

/-! ## Rational ↔ decimal string

    Every rational on the wire is a string (`"3"`, `"-5/7"`,
    `"22/7"`). The Lean side parses it back exactly; rationals never
    go through `Float`. -/

/-- Render a `Rat` as a wire-format string.

    Uses Lean's built-in `Rat.toString` shape: `"n"` when the denominator
    is `1`, otherwise `"n/d"`. -/
def ratToWire (q : Rat) : String := toString q

/-- Parse an unsigned `Nat` from a non-empty decimal string. Rejects
    empty input, leading `+`, leading zeros on a multi-digit run
    (`"01"` is an error), and any non-digit character. -/
private def parseNatStrict (s : String) : Except String Nat := do
  if s.isEmpty then throw "empty integer"
  if s.length > 1 ∧ s.front = '0' then
    throw s!"leading zero in '{s}'"
  let mut acc : Nat := 0
  for c in s.toList do
    if c.isDigit then
      acc := acc * 10 + (c.toNat - '0'.toNat)
    else
      throw s!"non-digit '{c}' in '{s}'"
  pure acc

/-- Parse a signed `Int` from a decimal string. Accepts an optional
    leading `-`; rejects a leading `+`. -/
private def parseIntStrict (s : String) : Except String Int := do
  if s.isEmpty then throw "empty integer"
  if s.front = '-' then
    let n ← parseNatStrict (s.drop 1).copy
    pure (-(n : Int))
  else
    let n ← parseNatStrict s
    pure (n : Int)

/-- Parse a `Rat` from a wire-format string. Accepts `"n"` and
    `"n/d"`; rejects whitespace, leading `+`, empty parts,
    denominator zero, and anything else. -/
def ratFromWire (s : String) : Except String Rat := do
  match s.splitOn "/" with
  | [n] =>
    let i ← parseIntStrict n
    pure (Rat.ofInt i)
  | [n, d] =>
    let i ← parseIntStrict n
    let dn ← parseNatStrict d
    if dn = 0 then throw s!"zero denominator in '{s}'"
    pure (mkRat i dn)
  | _ => throw s!"malformed rational '{s}'"

/-! ## Request encoder -/

/-- The string token used for an objective sense on the wire. -/
private def senseToWire : ObjSense → String
  | .minimize => "minimize"
  | .maximize => "maximize"

private def simplexToWire : Simplex → String
  | .primal => "primal"
  | .dual   => "dual"
  | .auto   => "auto"

/-- Encode an `Option Rat` bound: `null` for `±∞`, decimal string
    otherwise. -/
private def encodeBound : Option Rat → Json
  | none   => Json.null
  | some q => Json.str (ratToWire q)

/-- Convert a wall-clock `timeLimit` in seconds to the integer
    millisecond value the wire carries. Non-positive and
    non-finite inputs collapse to `none`. -/
private def timeLimitMs : Option Float → Option Nat
  | none   => none
  | some s =>
    if s.isNaN ∨ ¬ s.isFinite ∨ s ≤ 0 then none
    else some (s * 1000.0).toUInt64.toNat

/-- Encode `Options` as the `"options"` sub-object. `presolve` is
    forced to `false` on the wire so the verifier downstream runs
    against the original LP, not whatever SoPlex's presolve
    transformed it into (see `docs/json-contract.md`). -/
def encodeOptions (o : Options) : Json :=
  let iter : Json := match o.iterLimit with
    | none   => Json.null
    | some n => Json.num n
  let tlim : Json := match timeLimitMs o.timeLimit with
    | none   => Json.null
    | some n => Json.num n
  Json.mkObj
    [ ("sense",       Json.str (senseToWire o.sense)),
      ("presolve",    Json.bool false),
      ("simplex",     Json.str (simplexToWire o.simplex)),
      ("iterLimit",   iter),
      ("timeLimitMs", tlim) ]

/-- Encode a `Problem` as the `"problem"` sub-object. -/
def encodeProblem {m n : Nat} (p : Problem m n) : Json :=
  let c : Json := Json.arr (p.c.toArray.map fun q => Json.str (ratToWire q))
  let aEntries : Json := Json.arr <| p.a.map fun (r, c, v) =>
    Json.arr #[Json.num r.val, Json.num c.val, Json.str (ratToWire v)]
  let rowBounds : Json := Json.arr <| p.rowBounds.toArray.map fun (lo, hi) =>
    Json.arr #[encodeBound lo, encodeBound hi]
  let colBounds : Json := Json.arr <| p.colBounds.toArray.map fun (lo, hi) =>
    Json.arr #[encodeBound lo, encodeBound hi]
  Json.mkObj
    [ ("numConstraints", Json.num m),
      ("numVars",        Json.num n),
      ("c",              c),
      ("objOffset",      Json.str (ratToWire p.objOffset)),
      ("a",              aEntries),
      ("rowBounds",      rowBounds),
      ("colBounds",      colBounds) ]

/-- Encode a `(Options, Problem)` pair as the request JSON string the
    binary reads from stdin. -/
def encodeRequest {m n : Nat} (o : Options) (p : Problem m n) : String :=
  let req := Json.mkObj
    [ ("options", encodeOptions o),
      ("problem", encodeProblem p) ]
  req.compress

/-! ## Response decoder -/

/-- Wire-format status string → `SolveStatus`. -/
private def statusFromWire : String → Except String SolveStatus
  | "optimal"        => pure .optimal
  | "infeasible"     => pure .infeasible
  | "unbounded"      => pure .unbounded
  | "timeLimit"      => pure .timeLimit
  | "iterLimit"      => pure .iterLimit
  | "numericFailure" => pure .numericFailure
  | "aborted"        => pure .aborted
  | s                => throw s!"unknown status '{s}'"

/-- Decode a length-`k` vector of rationals from a JSON array of
    decimal strings. -/
private def decodeRatVector (j : Json) (k : Nat) (field : String) :
    Except String (Vector Rat k) := do
  let arr ← j.getArr?
  if h : arr.size = k then
    let mapped : { bs : Array Rat // bs.size = arr.size } ←
      Array.mapM' (fun e => do ratFromWire (← e.getStr?)) arr
    pure ⟨mapped.val, by rw [mapped.property, h]⟩
  else
    throw s!"{field}: expected length {k}, got {arr.size}"

/-- Pull the `dual` array (length = `numConstraints`) out of the
    response and split it into a `DualBundle`. Wire semantics: each
    entry is a signed row multiplier. We decompose it into the
    nonneg `rowLower` / `rowUpper` split required by `DualBundle`:
    a positive entry goes to `rowLower`, a negative entry's
    absolute value goes to `rowUpper`. Column duals are not on the
    wire and default to zero. -/
private def decodeDualBundle (j : Json) (m n : Nat) :
    Except String (DualBundle m n) := do
  let row ← decodeRatVector j m "dual"
  let rowLower : Vector Rat m :=
    Vector.ofFn fun i => if row[i] ≥ (0 : Rat) then row[i] else 0
  let rowUpper : Vector Rat m :=
    Vector.ofFn fun i => if row[i] ≥ (0 : Rat) then 0 else -row[i]
  let zerosN : Vector Rat n := Vector.ofFn fun _ => (0 : Rat)
  pure { rowLower := rowLower, rowUpper := rowUpper,
         colLower := zerosN, colUpper := zerosN }

/-- The recoverable error envelope a binary writes when it cannot
    complete a solve cleanly. Returned by `decodeResponse` so the
    caller can surface the diagnostic verbatim through
    `SolveError.bridge`. -/
inductive Decoded (m n : Nat)
  | solution (s : Solution m n)
  | wireError (msg : String)
  deriving Repr

/-- Decode a stdout response into either a `Solution` or the
    `{ "error": ... }` envelope. The caller is responsible for
    wrapping the envelope into a `SolveError.bridge`; this layer
    just reports what was on the wire. -/
def decodeResponse (m n : Nat) (s : String) :
    Except String (Decoded m n) := do
  let j ← Json.parse s
  -- Error envelope short-circuits everything else. The spec defines
  -- `error` as a human-readable string; an `error` field with another
  -- shape is a protocol bug, not a recoverable wire error.
  match j.getObjVal? "error" with
  | .ok eJ =>
    match eJ.getStr? with
    | .ok msg => return .wireError msg
    | .error _ =>
      throw s!"error envelope value is not a string: {eJ.compress}"
  | .error _ => pure ()
  let statusStr ← j.getObjVal? "status" >>= Json.getStr?
  let status ← statusFromWire statusStr
  -- `certificate` itself must be a JSON object; only its `primal` and
  -- `dual` fields are independently optional. A non-object certificate
  -- is malformed wire data, not a missing-field-is-unchecked case.
  let certJ ← j.getObjVal? "certificate"
  let _ ← certJ.getObj? -- reject arrays, strings, etc.
  let primalJ := certJ.getObjValD "primal"
  let dualJ   := certJ.getObjValD "dual"
  -- `unbounded` puts the ray of recession in the wire's `primal` slot;
  -- every other status puts a feasible point there.
  let primalRay ← match status, primalJ.isNull with
    | _, true =>
      pure (α := Option (Vector Rat n) × Option (Vector Rat n)) (none, none)
    | .unbounded, false =>
      let v ← decodeRatVector primalJ n "certificate.primal (ray)"
      pure (none, some v)
    | _, false =>
      let v ← decodeRatVector primalJ n "certificate.primal"
      pure (some v, none)
  let (primal, ray) := primalRay
  let dual ←
    if dualJ.isNull then pure (α := Option (DualBundle m n)) none
    else (do let db ← decodeDualBundle dualJ m n; pure (some db))
  let cert : Certificate m n :=
    { primal := primal, dual := dual, ray := ray }
  let sol : Solution m n :=
    { status := status, objective := none, certificate := cert, log := "" }
  pure (.solution sol)

end Soplex.Backend.SoplexJSON
