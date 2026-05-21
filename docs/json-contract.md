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

(falling back to `soplex` on `$PATH` if the env var is unset), then
writes the request to stdin and reads the response from stdout.

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
    "primal": ["<Rat>", ...] | null,   // length = numVars when present
    "dual":   ["<Rat>", ...] | null    // length = numConstraints when present
  }
}
```

- Terminal statuses (`optimal`, `infeasible`, `unbounded`) MUST
  carry the certificate field appropriate to that status:
  - `optimal`     → both `primal` and `dual`
  - `infeasible`  → `dual` only (Farkas certificate)
  - `unbounded`   → `primal` only (ray of recession)
  Missing-field-for-terminal-status surfaces in the verifier as
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

For now, this `kim-em/lp-backend-soplex-json` repository is the
canonical spec — any third-party implementation should cite a
specific commit of this file.
