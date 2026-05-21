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

/-- The string token used on the wire to mean "unbounded above/below"
    for an optional `Rat` bound. Picked to avoid ambiguity with a
    legitimate rational that happens to spell `null`. -/
def unboundedToken : String := "null"

end Soplex.Backend.SoplexJSON
