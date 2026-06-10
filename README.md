# LPBackendSoplexJSON

[![Lean](https://img.shields.io/badge/Lean-4.31.0--rc1-blue.svg)](./lean-toolchain)
[![License](https://img.shields.io/github/license/leanprover/lp-backend-soplex-json.svg)](./LICENSE)

> **New here? Start at [`leanprover/lp`](https://github.com/leanprover/lp)** — the entry
> point for the `lp` / `maximize` tactics and the verified LP solver. This repository is one
> package of that family: the out-of-process JSON backend (experimental).

Out-of-process `LPBackend` adapter for the `by lp` tactic registry.
Drives an external `soplex` binary on `$PATH` (or anywhere on disk
via `LP_BACKEND_SOPLEX_JSON_BIN`) through a JSON stdio protocol,
and self-registers with the
[`leanprover/lp-tactic`](https://github.com/leanprover/lp-tactic) registry
under priority 50 ("subprocess band") on import.

This is the "I already have SoPlex installed, please don't rebuild
it" backend. The build graph carries *no* native deps — no GMP, no
Boost, no SoPlex headers. SoPlex enters the picture at *runtime*,
when `solveExact` is called and the backend spawns the binary. If
you'd rather pin a specific SoPlex build inside Lake, depend on
[`leanprover/lp-backend-soplex-ffi`](https://github.com/leanprover/lp-backend-soplex-ffi)
instead.

The wire format ([`docs/json-contract.md`](./docs/json-contract.md))
is the canonical interop spec. Any external tool that emits the
same JSON shape (a Python harness driving HiGHS, a Rust shim, the
[soplex CLI](https://soplex.zib.de/) once a JSON-mode wrapper
lands, etc.) can serve as a drop-in backend by editing the
`solveExact` invocation to point at it.

## Quickstart

```lean
require LPBackendSoplexJSON from git
  "https://github.com/leanprover/lp-backend-soplex-json" @ "main"
```

```lean
import LPTactic
import LPBackendSoplexJSON  -- registers "soplex-json" at priority 50

-- With LP_BACKEND_SOPLEX_JSON_BIN pointing at a binary that speaks
-- the JSON contract, `by lp` dispatches to it:
example (a b : Rat) (_ : 2 * a + b ≤ 5) (_ : a - b ≤ 1) :
    3 * a ≤ 6 := by lp
```

Point the backend at the JSON-speaking binary:

```sh
export LP_BACKEND_SOPLEX_JSON_BIN=/path/to/soplex-json-wrapper
```

**A stock `soplex` binary (e.g. from `brew install soplex`) is not
sufficient**: the backend invokes the binary as
`<bin> --solve --json` and exchanges the JSON wire format on
stdin/stdout, which the upstream SoPlex CLI does not implement. You
need a wrapper that speaks the contract — that is the point of this
package: any external tool that does (a Python harness driving
HiGHS, a Rust shim around SoPlex, …) becomes a drop-in `by lp`
backend.

## Status

Experimental. The Lean side is implemented and tested: the encoder /
decoder for the wire format in
[`docs/json-contract.md`](./docs/json-contract.md) live in
`Contract.lean` (round-trip tests in
`LPBackendSoplexJSONTest/Contract.lean`), and `solveExact` spawns the
binary, writes the request, and decodes the response (subprocess
behavioral tests in `LPBackendSoplexJSONTest/Subprocess.lean`, using a
stub binary — no SoPlex install needed in CI). What does not exist
yet is a published JSON-speaking solver wrapper; until one ships,
registering the package gets you the registry slot, the probe
diagnostics, and a backend that works against your own wrapper.

## Layout

```
LPBackendSoplexJSON.lean         # top-level import
LPBackendSoplexJSON/
  Backend.lean                   # def backend : LPBackend, probe, solveExact
  Contract.lean                  # JSON encoder/decoder
LPBackendSoplexJSONTest/         # `lake test` suites (contract + subprocess)
docs/json-contract.md            # the wire-format spec
```

The backend lives under `namespace LP.Backend.SoplexJSON`,
mirroring the layout of
[`leanprover/lp-backend-soplex-ffi`](https://github.com/leanprover/lp-backend-soplex-ffi).

## Licence

[Apache License 2.0](./LICENSE).
