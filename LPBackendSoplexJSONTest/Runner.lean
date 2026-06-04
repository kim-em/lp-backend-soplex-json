/-
  `lake test` entry point for `leanprover/lp-backend-soplex-json`.
  Runs every test suite in the package.
-/

import LPBackendSoplexJSONTest.Contract
import LPBackendSoplexJSONTest.Subprocess

def main : IO UInt32 := do
  let a ← LPBackendSoplexJSONTest.Contract.main
  let b ← LPBackendSoplexJSONTest.Subprocess.main
  pure (a + b)
