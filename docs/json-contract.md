# JSON wire-format contract

The out-of-process SoPlex backend in this repository drives an
external `soplex` (or compatible) binary through a JSON stdio
protocol. This document is the normative spec — any external tool
that emits the same JSON shape (a Python harness driving HiGHS, a
Rust shim, etc.) can serve as a drop-in backend.

## Invocation

The Lean side runs the binary as

```
$LP_BACKEND_SOPLEX_JSON_BIN [--solve --json]
```

If the env var is unset, it falls back to the wrapper shipped in
this repository (`scripts/soplex-json-wrapper.py`), which drives a
stock `soplex` CLI underneath. The env var stays the override for a
custom wrapper (a HiGHS harness, a Rust shim, etc.). Either way the
Lean side then writes the request to stdin and reads the response
from stdout. The registry probe uses the same path: it sends the
trivial request `minimize x, x ≥ 0` (one variable, no rows) and
requires a decodable response, so a binary that does not speak this
contract is reported as unavailable before any real solve is
attempted.

Stderr is captured and surfaced through `SolveError.bridge` on
non-zero exit. The Lean side closes stdin after writing the
request, so the binary should treat `EOF` on stdin as
"request complete, please respond."

## Why JSON, not LP/MPS?

The Lean verifier consumes *exact* rationals — the existing
`SoplexFFI.solveExact` returns rationals as denom/numer pairs of
arbitrary-precision integers. Round-tripping through a textual LP
or MPS file would force decimal fixed-point or IEEE 754 floats,
which would silently corrupt the kernel-checked solution.

So every rational in the wire format travels as a decimal string
(`"3"`, `"-5/7"`, `"22/7"`), *not* as a JSON number. The Lean side
parses the string back into a `Rat` exactly.

## Request shape (stdin)

```json
{
  "options": {
    "sense": "minimize" | "maximize",
    "presolve": false,
    "simplex": "primal" | "dual" | "auto",
    "iterLimit": null | <Nat>,
    "timeLimitMs": null | <Nat>
  },
  "problem": {
    "numConstraints": <Nat>,
    "numVars": <Nat>,
    "c": ["<Rat>", ...],            // length = numVars
    "objOffset": "<Rat>",
    "a": [[<row>, <col>, "<Rat>"], ...],  // sparse, 0-indexed
    "rowBounds": [["<Rat>"|null, "<Rat>"|null], ...],  // length = numConstraints
    "colBounds": [["<Rat>"|null, "<Rat>"|null], ...]   // length = numVars
  }
}
```

- `null` in a bound pair means ±∞. The pair `[null, "5"]` is `≤ 5`.
  The pair `["0", null]` is `≥ 0`. The pair `["3", "3"]` is `= 3`.
- `a` entries are sparse triples. Missing `(row, col)` pairs are
  implicit zero. Duplicate `(row, col)` entries are an error.
- `presolve` is always reported as `false` on the wire even if the
  user requested `true`: the verifier must run against the
  normalised input LP, not whatever SoPlex's presolve transformed
  it into. The Lean side enforces this; the backend should not
  re-enable presolve.

## Response shape (stdout)

```json
{
  "status": "optimal" | "infeasible" | "unbounded"
          | "iterLimit" | "timeLimit" | "numericFailure" | "aborted",
  "certificate": {
    "primal": ["<Rat>", ...] | null,   // feasible point; length = numVars
    "ray":    ["<Rat>", ...] | null,   // recession direction; length = numVars
    "dual": {
      "rowLower": ["<Rat>", ...],      // length = numConstraints
      "rowUpper": ["<Rat>", ...],      // length = numConstraints
      "colLower": ["<Rat>", ...],      // length = numVars
      "colUpper": ["<Rat>", ...]       // length = numVars
    } | null
  }
}
```

The certificate mirrors the verifier's `LPCore.Certificate` /
`LP.DualBundle` shape exactly, so everything the pure-Lean checker
can verify is expressible on the wire.

- `dual` is the canonical lower/upper split: all four vectors are
  nonnegative, with a coordinate zero whenever the matching bound is
  absent (`null` in the request). For an optimality certificate it
  must satisfy stationarity `Aᵀ(rowLower − rowUpper) + (colLower −
  colUpper) = c`; for a Farkas (infeasibility) certificate, the same
  with `= 0` and a strictly positive bound combination. The Lean
  verifier checks all of this; the wire layer only checks shape.
- Terminal statuses (`optimal`, `infeasible`, `unbounded`) MUST
  carry the certificate fields appropriate to that status:
  - `optimal`     → `primal` and `dual`
  - `infeasible`  → `dual` (Farkas certificate)
  - `unbounded`   → `primal` (a *feasible base point*) and `ray`
    (the improving recession direction) — both are required; the
    verifier cannot certify unboundedness from a ray alone.
  A missing field for a terminal status surfaces in the verifier as
  `.unchecked status` (not an error — the LP just didn't get
  proven).
- Non-terminal statuses pass through to the verifier as
  `.unchecked status`. The backend should set the certificate
  fields to `null` in those cases.

## Error envelope

If the binary cannot complete a solve cleanly — e.g. internal
abort, malformed request — it should write to stdout:

```json
{ "error": "<human-readable diagnostic>" }
```

The Lean side surfaces this verbatim through `SolveError.bridge`.
The diagnostic should be actionable (binary name, file path,
relevant numeric overflow, etc.).

## Version pinning

This document describes wire version `1`. A future incompatible
change would require a version tag in the request and a versioned
response.

For now, this `leanprover/lp-backend-soplex-json` repository is the
canonical spec — any third-party implementation should cite a
specific commit of this file.
