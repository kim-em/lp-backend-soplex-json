/-
  `lake test` entry point for `kim-em/lp-backend-soplex-json`.
  Runs every test suite in the package; today just the contract
  encoder/decoder round-trip tests.
-/

import LPBackendSoplexJSONTest.Contract

def main : IO UInt32 :=
  LPBackendSoplexJSONTest.Contract.main
