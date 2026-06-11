#!/usr/bin/env python3
"""Contract-speaking SoPlex wrapper for ``leanprover/lp-backend-soplex-json``.

The Lean backend (``LPBackendSoplexJSON.Backend``) spawns a binary as
``<bin> --solve --json``, writes a JSON request to its stdin, and reads a JSON
response from its stdout. The stock ``soplex`` CLI does not implement that
protocol; this script does, by driving the stock CLI underneath:

  * translate the JSON request into a CPLEX-LP file plus CLI flags,
  * run ``soplex`` with exact-rational solving and rational solution printing
    enabled (``--readmode=1 --solvemode=2 -f0 -o0``, presolve off),
  * parse the exact rational primal / dual / ray values back out, and
  * emit the JSON response in the four-vector dual-bundle shape that the
    verifier's ``LPCore.Certificate`` consumes.

Only the Python standard library is used. See ``docs/json-contract.md`` for the
normative wire spec; this file is the canonical first wrapper that speaks it.

The underlying CLI is found via ``$LP_BACKEND_SOPLEX_CLI`` (an absolute path or
a name on ``$PATH``), defaulting to ``soplex``.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from fractions import Fraction

WIRE_VERSION = 1


class WireError(Exception):
    """A diagnostic to be surfaced through the ``{ "error": ... }`` envelope."""


def fail(msg: str) -> "None":
    """Emit the documented error envelope on stdout and exit cleanly.

    The Lean side surfaces this verbatim through ``SolveError.bridge``; a
    non-zero exit is unnecessary (and the envelope wins over the exit code
    anyway), but we exit 0 so the diagnostic is unambiguously the envelope.
    """
    json.dump({"error": msg}, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
    sys.exit(0)


# --- wire rationals -------------------------------------------------------

def rat_of_wire(s: str, where: str) -> Fraction:
    """Parse a wire rational (``"3"`` or ``"-5/7"``) exactly. No float detour."""
    try:
        return Fraction(s)
    except (ValueError, ZeroDivisionError):
        raise WireError(f"malformed rational at {where}: {s!r}")


def wire_of_rat(q: Fraction) -> str:
    """Render a Fraction in the wire shape: ``"n"`` or ``"n/d"`` (matches
    Lean's ``Rat.toString``)."""
    if q.denominator == 1:
        return str(q.numerator)
    return f"{q.numerator}/{q.denominator}"


def opt_bound(pair, where: str):
    """Parse a ``[lo|null, hi|null]`` bound pair into ``(Fraction|None, ...)``."""
    if not isinstance(pair, list) or len(pair) != 2:
        raise WireError(f"{where}: expected a [lo, hi] pair, got {pair!r}")
    lo, hi = pair
    lo = None if lo is None else rat_of_wire(lo, f"{where}.lo")
    hi = None if hi is None else rat_of_wire(hi, f"{where}.hi")
    return lo, hi


# --- request --------------------------------------------------------------

class Request:
    def __init__(self, raw: dict):
        opts = raw.get("options", {})
        prob = raw.get("problem")
        if not isinstance(prob, dict):
            raise WireError("request has no 'problem' object")
        self.sense = opts.get("sense", "minimize")
        if self.sense not in ("minimize", "maximize"):
            raise WireError(f"unknown sense {self.sense!r}")
        self.iter_limit = opts.get("iterLimit")
        self.time_limit_ms = opts.get("timeLimitMs")

        self.m = int(prob["numConstraints"])
        self.n = int(prob["numVars"])

        c = prob["c"]
        if len(c) != self.n:
            raise WireError(f"c: expected length {self.n}, got {len(c)}")
        # Canonicalize to minimization: the verifier checks certificates
        # against `canonicalize sense p`, which negates the objective for
        # `maximize`. So solving min(c') with c' = (sense==max ? -c : c)
        # produces a primal/dual/ray already in the form the verifier wants.
        # objOffset never affects the argmin or the multipliers, so we drop it.
        sign = -1 if self.sense == "maximize" else 1
        self.c = [sign * rat_of_wire(v, f"c[{j}]") for j, v in enumerate(c)]

        self.a = []  # list of (row, col, Fraction)
        seen = set()
        for k, entry in enumerate(prob.get("a", [])):
            if not isinstance(entry, list) or len(entry) != 3:
                raise WireError(f"a[{k}]: expected [row, col, value]")
            r, col, v = int(entry[0]), int(entry[1]), rat_of_wire(entry[2], f"a[{k}].v")
            if not (0 <= r < self.m and 0 <= col < self.n):
                raise WireError(f"a[{k}]: index ({r},{col}) out of range")
            if (r, col) in seen:
                raise WireError(f"a[{k}]: duplicate entry ({r},{col})")
            seen.add((r, col))
            if v != 0:
                self.a.append((r, col, v))

        rb = prob["rowBounds"]
        if len(rb) != self.m:
            raise WireError(f"rowBounds: expected length {self.m}, got {len(rb)}")
        self.row_bounds = [opt_bound(p, f"rowBounds[{i}]") for i, p in enumerate(rb)]

        cb = prob["colBounds"]
        if len(cb) != self.n:
            raise WireError(f"colBounds: expected length {self.n}, got {len(cb)}")
        self.col_bounds = [opt_bound(p, f"colBounds[{j}]") for j, p in enumerate(cb)]


# --- LP emission ----------------------------------------------------------

def lp_coeff(q: Fraction) -> str:
    """An LP-format magnitude token. SoPlex's rational reader parses
    ``"n"`` and ``"n/d"`` exactly (verified empirically)."""
    if q.denominator == 1:
        return str(q.numerator)
    return f"{q.numerator}/{q.denominator}"


def linear_terms(coeffs) -> str:
    """Render ``Σ coeffs[j] x_j`` with explicit per-term signs, wrapping a few
    terms per line. Zero coefficients are kept so every column is declared."""
    pieces = []
    for j, q in coeffs:
        op = "-" if q < 0 else "+"
        pieces.append(f"{op} {lp_coeff(abs(q))} x{j}")
    if not pieces:
        return "+ 0 x0"
    out, line = [], []
    for p in pieces:
        line.append(p)
        if len(line) >= 8:
            out.append(" ".join(line))
            line = []
    if line:
        out.append(" ".join(line))
    return "\n    ".join(out)


def build_lp(req: Request):
    """Build the LP text and the row-name -> original-row-index map.

    Ranged rows (both bounds finite, lo < hi) are split into a ``>=`` row
    ``c{i}L`` and a ``<=`` row ``c{i}U``; the dual multipliers recombine into
    the row's (rowLower, rowUpper) split on the way back."""
    lines = ["Minimize"]
    lines.append("  obj: " + linear_terms(list(enumerate(req.c))))
    lines.append("Subject To")

    # Map LP row name -> (original row index, side) where side in {"=","L","U"}.
    row_names = {}
    # Precompute each row's coefficient list from the sparse matrix.
    row_coeffs = {i: [] for i in range(req.m)}
    for (r, col, v) in req.a:
        row_coeffs[r].append((col, v))

    for i in range(req.m):
        lo, hi = req.row_bounds[i]
        coeffs = sorted(row_coeffs[i])
        expr = linear_terms(coeffs) if coeffs else "+ 0 x0"
        if lo is None and hi is None:
            # Free row: contributes nothing; its multipliers stay zero.
            continue
        if lo is not None and hi is not None and lo == hi:
            lines.append(f"  c{i}: {expr} = {lp_coeff(lo)}")
            row_names[f"c{i}"] = (i, "=")
        elif lo is not None and hi is not None:
            lines.append(f"  c{i}L: {expr} >= {lp_coeff(lo)}")
            lines.append(f"  c{i}U: {expr} <= {lp_coeff(hi)}")
            row_names[f"c{i}L"] = (i, "L")
            row_names[f"c{i}U"] = (i, "U")
        elif lo is not None:
            lines.append(f"  c{i}: {expr} >= {lp_coeff(lo)}")
            row_names[f"c{i}"] = (i, "=")
        else:  # hi is not None
            lines.append(f"  c{i}: {expr} <= {lp_coeff(hi)}")
            row_names[f"c{i}"] = (i, "=")

    lines.append("Bounds")
    for j in range(req.n):
        lo, hi = req.col_bounds[j]
        if lo is None and hi is None:
            lines.append(f"  x{j} free")
        elif lo is None:
            lines.append(f"  -infinity <= x{j} <= {lp_coeff(hi)}")
        elif hi is None:
            lines.append(f"  x{j} >= {lp_coeff(lo)}")
        else:
            lines.append(f"  {lp_coeff(lo)} <= x{j} <= {lp_coeff(hi)}")
    lines.append("End")
    return "\n".join(lines) + "\n", row_names


# --- SoPlex invocation + output parsing -----------------------------------

def soplex_cli() -> str:
    cli = os.environ.get("LP_BACKEND_SOPLEX_CLI", "soplex")
    resolved = shutil.which(cli) or (cli if os.path.isabs(cli) and os.path.exists(cli) else None)
    if resolved is None:
        raise WireError(
            f"could not find the SoPlex CLI {cli!r} "
            f"(set $LP_BACKEND_SOPLEX_CLI to an absolute path or install soplex)"
        )
    return resolved


def run_soplex(req: Request, lp_path: str):
    """Run SoPlex on `lp_path`; return `(stdout, stderr)`. Raises `WireError`
    on a spawn failure, a non-zero exit, or a rejected LP file."""
    args = [
        soplex_cli(),
        "--readmode=1",    # parse the LP file as exact rationals
        "--solvemode=2",   # exact rational solve
        "-s0",             # presolve off (the contract forbids re-enabling it)
        "-f0", "-o0",      # zero tolerances: force refinement to the exact value
        "-X", "-Y",        # print primal / dual multipliers as rationals
    ]
    # `timeLimitMs` is integer milliseconds; SoPlex's -t takes seconds.
    if isinstance(req.time_limit_ms, int) and req.time_limit_ms > 0:
        args.append(f"-t{req.time_limit_ms / 1000.0}")
    if isinstance(req.iter_limit, int) and req.iter_limit > 0:
        args.append(f"-i{req.iter_limit}")
    args.append(lp_path)
    try:
        proc = subprocess.run(args, capture_output=True, text=True)
    except OSError as e:
        raise WireError(f"could not spawn SoPlex: {e}")
    # SoPlex exits 0 for optimal / infeasible / unbounded (it solved the LP);
    # a non-zero exit is a genuine failure (abort, missing GMP support, …).
    if proc.returncode != 0:
        raise WireError(
            f"SoPlex exited with code {proc.returncode}: "
            f"stderr={tail(proc.stderr)}; stdout={tail(proc.stdout)}"
        )
    if "Error while reading file" in proc.stdout or "Syntax error" in proc.stdout:
        raise WireError(
            f"SoPlex rejected the generated LP file: {first_error(proc.stdout)}"
        )
    return proc.stdout, proc.stderr


def first_error(text: str) -> str:
    for line in text.splitlines():
        if "error" in line.lower():
            return line.strip()
    return "(no diagnostic captured)"


def tail(text: str, limit: int = 400) -> str:
    """The trailing `limit` characters of `text`, whitespace-trimmed."""
    t = text.strip()
    return t if len(t) <= limit else "…" + t[-limit:]


def parse_status(text: str, stderr: str = "") -> str:
    """Map the ``SoPlex status : problem is solved [<x>]`` line to a wire
    status. Non-terminal outcomes (limits, failures) pass through; the verifier
    treats them as ``.unchecked``."""
    line = ""
    for ln in text.splitlines():
        if "SoPlex status" in ln:
            line = ln.lower()
            break
    if not line:
        # No status line: usually a rejected flag (SoPlex prints usage to
        # stderr and still exits 0). Surface whatever diagnostic we have.
        raise WireError(
            f"no SoPlex status line; stderr={tail(stderr)}; stdout={tail(text)}"
        )
    if "optimal" in line:
        return "optimal"
    if "infeasible" in line:
        return "infeasible"
    if "unbounded" in line:
        return "unbounded"
    if "time limit" in line:
        return "timeLimit"
    if "iteration limit" in line or "abort iteration" in line:
        return "iterLimit"
    return "aborted"


def parse_sections(text: str) -> dict:
    """Parse SoPlex's ``(name, value):`` blocks into ``{header: {name: Fraction}}``.

    Each block is a header line ending in ``(name, value):`` followed by
    tab-separated ``name<TAB>value`` rows (the value is right-justified, so we
    split on whitespace), terminated by a blank line or an ``All other ...``
    line."""
    headers = {
        "Primal solution": "primal",
        "Dual solution": "dual",
        "Reduced costs": "reduced",
        "Primal ray": "primalRay",
        "Dual ray": "dualRay",
    }
    out = {v: {} for v in headers.values()}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        key = None
        for prefix, name in headers.items():
            if line.startswith(prefix) and line.rstrip().endswith("(name, value):"):
                key = name
                break
        if key is None:
            i += 1
            continue
        i += 1
        while i < len(lines):
            row = lines[i]
            if not row.strip() or row.lstrip().startswith("All other"):
                break
            parts = row.split()
            if len(parts) >= 2:
                try:
                    out[key][parts[0]] = Fraction(parts[-1])
                except ValueError:
                    pass  # ignore non-rational rows (e.g. stray log lines)
            i += 1
    return out


# --- certificate assembly -------------------------------------------------

def split_signed(value: Fraction):
    """Split a signed multiplier into the nonnegative (lower, upper) pair."""
    if value > 0:
        return value, Fraction(0)
    if value < 0:
        return Fraction(0), -value
    return Fraction(0), Fraction(0)


def assemble_row_duals(req: Request, named: dict, row_names: dict):
    """Fold per-LP-row multipliers (possibly split for ranged rows) into the
    per-original-row (rowLower, rowUpper) split."""
    row_lower = [Fraction(0)] * req.m
    row_upper = [Fraction(0)] * req.m
    for name, val in named.items():
        info = row_names.get(name)
        if info is None:
            continue
        i, side = info
        if side == "L":
            row_lower[i] = val            # multiplier on the `>=` half (>= 0)
        elif side == "U":
            row_upper[i] = -val           # multiplier on the `<=` half (<= 0)
        else:  # "=" — equality or one-sided row; sign selects the side
            lo, hi = split_signed(val)
            row_lower[i], row_upper[i] = lo, hi
    return row_lower, row_upper


def aty(req: Request, y):
    """Compute ``(Aᵀ y)_j`` for the signed row multiplier ``y`` (length m)."""
    out = [Fraction(0)] * req.n
    for (r, col, v) in req.a:
        out[col] += v * y[r]
    return out


def dual_bundle(row_lower, row_upper, col_lower, col_upper):
    return {
        "rowLower": [wire_of_rat(q) for q in row_lower],
        "rowUpper": [wire_of_rat(q) for q in row_upper],
        "colLower": [wire_of_rat(q) for q in col_lower],
        "colUpper": [wire_of_rat(q) for q in col_upper],
    }


def vec_frac(named: dict, n: int):
    """Gather a length-`n` Fraction vector from `x{j}` rows (zero elsewhere)."""
    out = [Fraction(0)] * n
    for name, val in named.items():
        if name.startswith("x"):
            try:
                j = int(name[1:])
            except ValueError:
                continue
            if 0 <= j < n:
                out[j] = val
    return out


def eval_ax(req: Request, x):
    """Compute ``(A x)_i`` (length m)."""
    out = [Fraction(0)] * req.m
    for (r, col, v) in req.a:
        out[r] += v * x[col]
    return out


# --- self-verification (mirrors LPVerify/Bool.lean exactly) ---------------
#
# The wrapper checks every certificate in exact arithmetic before emitting a
# terminal status, against the canonicalized (minimized) objective `req.c`.
# This is the same set of equations the Lean verifier runs, so a certificate
# that passes here is one the verifier accepts; one that fails becomes an
# actionable error envelope instead of a silently-rejected `.unchecked`.

def _primal_feasible(req: Request, x) -> bool:
    for j in range(req.n):
        lo, hi = req.col_bounds[j]
        if (lo is not None and x[j] < lo) or (hi is not None and x[j] > hi):
            return False
    ax = eval_ax(req, x)
    for i in range(req.m):
        lo, hi = req.row_bounds[i]
        if (lo is not None and ax[i] < lo) or (hi is not None and ax[i] > hi):
            return False
    return True


def _dual_nonneg_zero_absent(req: Request, rl, ru, cl, cu) -> bool:
    for i in range(req.m):
        lo, hi = req.row_bounds[i]
        if rl[i] < 0 or ru[i] < 0:
            return False
        if (lo is None and rl[i] != 0) or (hi is None and ru[i] != 0):
            return False
    for j in range(req.n):
        lo, hi = req.col_bounds[j]
        if cl[j] < 0 or cu[j] < 0:
            return False
        if (lo is None and cl[j] != 0) or (hi is None and cu[j] != 0):
            return False
    return True


def _stationarity(req: Request, rl, ru, cl, cu, target) -> bool:
    """`Aᵀ(rl − ru) + (cl − cu) == target`."""
    at = aty(req, [rl[i] - ru[i] for i in range(req.m)])
    return all(at[j] + (cl[j] - cu[j]) == target[j] for j in range(req.n))


def _bound_combination(req: Request, rl, ru, cl, cu) -> Fraction:
    total = Fraction(0)
    for i in range(req.m):
        lo, hi = req.row_bounds[i]
        if lo is not None:
            total += rl[i] * lo
        if hi is not None:
            total -= ru[i] * hi
    for j in range(req.n):
        lo, hi = req.col_bounds[j]
        if lo is not None:
            total += cl[j] * lo
        if hi is not None:
            total -= cu[j] * hi
    return total


def _recession_ray(req: Request, r) -> bool:
    for j in range(req.n):
        lo, hi = req.col_bounds[j]
        if (lo is not None and r[j] < 0) or (hi is not None and r[j] > 0):
            return False
    ar = eval_ax(req, r)
    for i in range(req.m):
        lo, hi = req.row_bounds[i]
        if (lo is not None and ar[i] < 0) or (hi is not None and ar[i] > 0):
            return False
    return True


def _dot(a, b) -> Fraction:
    return sum((a[i] * b[i] for i in range(len(a))), Fraction(0))


def certify_failure(status: str, soplex_out: str) -> str:
    return (
        f"wrapper could not build a verifiable certificate for SoPlex's "
        f"'{status}' result (likely a SoPlex output-format or sign-convention "
        f"mismatch); soplex output excerpt: {tail(soplex_out, 600)}"
    )


def build_response(req: Request, status: str, sections: dict, row_names: dict,
                   soplex_out: str) -> dict:
    cert = {"primal": None, "ray": None, "dual": None}
    if status == "optimal":
        x = vec_frac(sections["primal"], req.n)
        rl, ru = assemble_row_duals(req, sections["dual"], row_names)
        cl = [Fraction(0)] * req.n
        cu = [Fraction(0)] * req.n
        for name, val in sections["reduced"].items():
            if name.startswith("x"):
                try:
                    j = int(name[1:])
                except ValueError:
                    continue
                if 0 <= j < req.n:
                    cl[j], cu[j] = split_signed(val)
        ok = (_primal_feasible(req, x)
              and _dual_nonneg_zero_absent(req, rl, ru, cl, cu)
              and _stationarity(req, rl, ru, cl, cu, req.c)
              and _dot(req.c, x) == _bound_combination(req, rl, ru, cl, cu))
        if not ok:
            raise WireError(certify_failure("optimal", soplex_out))
        cert["primal"] = [wire_of_rat(q) for q in x]
        cert["dual"] = dual_bundle(rl, ru, cl, cu)
    elif status == "infeasible":
        # Farkas certificate: SoPlex prints the row part as a "Dual ray". The
        # column part is the implied reduced cost z = -Aᵀy of that ray.
        rl, ru = assemble_row_duals(req, sections["dualRay"], row_names)
        y = [rl[i] - ru[i] for i in range(req.m)]
        z = aty(req, y)
        cl = [Fraction(0)] * req.n
        cu = [Fraction(0)] * req.n
        for j in range(req.n):
            cl[j], cu[j] = split_signed(-z[j])
        ok = (_dual_nonneg_zero_absent(req, rl, ru, cl, cu)
              and _stationarity(req, rl, ru, cl, cu, [Fraction(0)] * req.n)
              and _bound_combination(req, rl, ru, cl, cu) > 0)
        if not ok:
            raise WireError(certify_failure("infeasible", soplex_out))
        cert["dual"] = dual_bundle(rl, ru, cl, cu)
    elif status == "unbounded":
        x = vec_frac(sections["primal"], req.n)      # feasible base point
        r = vec_frac(sections["primalRay"], req.n)   # improving recession ray
        ok = (_primal_feasible(req, x)
              and _recession_ray(req, r)
              and _dot(req.c, r) < 0)
        if not ok:
            raise WireError(certify_failure("unbounded", soplex_out))
        cert["primal"] = [wire_of_rat(q) for q in x]
        cert["ray"] = [wire_of_rat(q) for q in r]
    # Non-terminal statuses (limits, failures) carry a null certificate; the
    # verifier passes them through as `.unchecked`.
    return {"status": status, "certificate": cert}


def main() -> None:
    raw_in = sys.stdin.read()
    try:
        request = json.loads(raw_in)
    except json.JSONDecodeError as e:
        fail(f"request was not valid JSON: {e}")
        return
    try:
        req = Request(request)
        with tempfile.TemporaryDirectory(prefix="soplex-json-") as d:
            lp_path = os.path.join(d, "problem.lp")
            lp_text, row_names = build_lp(req)
            with open(lp_path, "w") as f:
                f.write(lp_text)
            out, err = run_soplex(req, lp_path)
        status = parse_status(out, err)
        sections = parse_sections(out)
        response = build_response(req, status, sections, row_names, out)
    except WireError as e:
        fail(str(e))
        return
    except Exception as e:  # never crash without an envelope the Lean side can read
        fail(f"internal wrapper error: {type(e).__name__}: {e}")
        return
    json.dump(response, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
