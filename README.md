# LPBackendSoplexJSON

[![Lean](https://img.shields.io/badge/Lean-4.31.0--rc1-blue.svg)](./lean-toolchain)
[![License](https://img.shields.io/github/license/leanprover/lp-backend-soplex-json.svg)](./LICENSE)

> **New here? Start at [`leanprover/lp`](https://github.com/leanprover/lp)** — the entry
> point for the `lp` / `maximize` tactics and the verified LP solver. This repository is one
> package of that family: the out-of-process JSON backend (experimental).

Out-of-process `LPBackend` adapter for the `by lp` tactic registry.
Drives a contract-speaking binary through a JSON stdio protocol, and
self-registers with the
[`leanprover/lp-tactic`](https://github.com/leanprover/lp-tactic) registry
under priority 50 ("subprocess band") on import.

This is the "I already have SoPlex installed, please don't rebuild
it" backend. The build graph carries *no* native deps — no GMP, no
Boost, no SoPlex headers. SoPlex enters the picture at *runtime*,
when `solveExact` is called and the backend spawns the binary. If
you'd rather pin a specific SoPlex build inside Lake, depend on
[`leanprover/lp-backend-soplex-ffi`](https://github.com/leanprover/lp-backend-soplex-ffi)
instead.

The package **ships a wrapper** that speaks the contract:
[`scripts/soplex-json-wrapper.py`](./scripts/soplex-json-wrapper.py)
(Python 3 stdlib only) translates each JSON request into an LP file,
runs the stock `soplex` CLI in exact-rational mode, and parses the
rational solution back into the wire response. So `brew install
soplex` + `import LPBackendSoplexJSON` is a working `by lp` with no
further configuration.

The wire format ([`docs/json-contract.md`](./docs/json-contract.md))
is the canonical interop spec. Any external tool that emits the
same JSON shape (a Python harness driving HiGHS, a Rust shim, etc.)
can serve as a drop-in backend — point `LP_BACKEND_SOPLEX_JSON_BIN`
at it.

## Quickstart

```lean
require LPBackendSoplexJSON from git
  "https://github.com/leanprover/lp-backend-soplex-json" @ "main"
```

```lean
import LPTactic
import LPBackendSoplexJSON  -- registers "soplex-json" at priority 50

-- With `soplex` on `$PATH` (e.g. `brew install soplex`), the shipped
-- wrapper makes `by lp` work out of the box:
example (a b : Rat) (_ : 2 * a + b ≤ 5) (_ : a - b ≤ 1) :
    3 * a ≤ 6 := by lp
```

Binary resolution, in order:

1. `$LP_BACKEND_SOPLEX_JSON_BIN`, if set — the override for a custom
   wrapper (a HiGHS harness, a Rust shim, …). Invoked as
   `<bin> --solve --json` with the JSON request on stdin.
2. otherwise the shipped wrapper, which drives a stock `soplex` CLI.
   The wrapper finds the CLI via `$LP_BACKEND_SOPLEX_CLI` (defaulting
   to `soplex` on `$PATH`).

```sh
# custom contract-speaking wrapper:
export LP_BACKEND_SOPLEX_JSON_BIN=/path/to/my-wrapper
# or just point the shipped wrapper at a specific soplex build:
export LP_BACKEND_SOPLEX_CLI=/opt/soplex/bin/soplex
```

A stock `soplex` install is enough because the **shipped wrapper**
bridges it to the contract: the upstream SoPlex CLI does not
implement `--solve --json` itself, so the wrapper generates the LP
file, runs `soplex --readmode=1 --solvemode=2` (exact rational
solve, presolve off) with rational solution printing, and emits the
four-vector dual bundle the verifier consumes — including the base
point and ray for unbounded results.

## Status

Experimental, but functional out of the box. The Lean side
(encoder / decoder in `Contract.lean`, subprocess driver and probe in
`Backend.lean`) and the shipped wrapper are implemented and tested.
`LPBackendSoplexJSONTest/Contract.lean` round-trips the wire format
with no solver; `LPBackendSoplexJSONTest/Subprocess.lean` drives the
real wrapper against an installed `soplex` and runs every certificate
it produces — optimal, infeasible, unbounded, maximize, fractional —
back through the verifier (cases self-skip when `soplex` is absent,
so CI without it still passes). CI installs `soplex` so the
end-to-end path is exercised.

## Layout

```
LPBackendSoplexJSON.lean         # top-level import
LPBackendSoplexJSON/
  Backend.lean                   # def backend : LPBackend, probe, solveExact, wrapper resolution
  Contract.lean                  # JSON encoder/decoder
scripts/soplex-json-wrapper.py   # the shipped contract-speaking wrapper (drives the soplex CLI)
LPBackendSoplexJSONTest/         # `lake test` suites (contract + subprocess + real wrapper)
docs/json-contract.md            # the wire-format spec
```

The backend lives under `namespace LP.Backend.SoplexJSON`,
mirroring the layout of
[`leanprover/lp-backend-soplex-ffi`](https://github.com/leanprover/lp-backend-soplex-ffi).

## Licence

[Apache License 2.0](./LICENSE).
