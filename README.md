# LPBackendSoplexJSON

[![Lean](https://img.shields.io/badge/Lean-4.29.1-blue.svg)](./lean-toolchain)
[![License](https://img.shields.io/github/license/kim-em/lp-backend-soplex-json.svg)](./LICENSE)

Out-of-process `LPBackend` adapter for the `by lp` tactic registry.
Drives an external `soplex` binary on `$PATH` (or anywhere on disk
via `LP_BACKEND_SOPLEX_JSON_BIN`) through a JSON stdio protocol,
and self-registers with the
[`kim-em/lp-tactic`](https://github.com/kim-em/lp-tactic) registry
under priority 50 ("subprocess band") on import.

This is the "I already have SoPlex installed, please don't rebuild
it" backend. The build graph carries *no* native deps — no GMP, no
Boost, no SoPlex headers. SoPlex enters the picture at *runtime*,
when `solveExact` is called and the backend spawns the binary. If
you'd rather pin a specific SoPlex build inside Lake, depend on
[`kim-em/lp-backend-soplex-ffi`](https://github.com/kim-em/lp-backend-soplex-ffi)
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
  "https://github.com/kim-em/lp-backend-soplex-json" @ "main"
```

```lean
import LPTactic
import LPBackendSoplexJSON  -- registers "soplex-json" at priority 50

-- With `brew install soplex` (or the equivalent), `by lp` now
-- dispatches to the out-of-process backend by default:
example (a b : Rat) (_ : 2 * a + b ≤ 5) (_ : a - b ≤ 1) :
    3 * a ≤ 6 := by lp
```

Override the binary location explicitly:

```sh
export LP_BACKEND_SOPLEX_JSON_BIN=/opt/scip-suite/bin/soplex
```

## Status

Today the backend ships a working `probe` (spawns
`soplex --version`, captures exit code) and a placeholder
`solveExact` that reports a structured "JSON encoder/decoder not
yet implemented" error. The wire-format spec in
[`docs/json-contract.md`](./docs/json-contract.md) is canonical;
the encoder/decoder connecting it to `Backend.lean`'s
`solveExact` is the follow-up work. Importing the module today is
already meaningful: it registers the backend so
`availableBackends` lists it, and the probe correctly reports
"is `soplex` installed?" diagnostics.

## Layout

```
LPBackendSoplexJSON.lean         # top-level import
LPBackendSoplexJSON/
  Backend.lean                   # def backend : LPBackend, probe, solveExact
  Contract.lean                  # JSON encoder/decoder (TODO)
docs/json-contract.md            # the wire-format spec
```

The backend lives under `namespace Soplex.Backend.SoplexJSON`,
mirroring the layout of
[`kim-em/lp-backend-soplex-ffi`](https://github.com/kim-em/lp-backend-soplex-ffi).

## Licence

[Apache License 2.0](./LICENSE).
