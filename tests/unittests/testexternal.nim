import nimgen/external

import unittest


suite "test external":
  ################## execAction ####################

  test "run a simple command":
    discard execAction("echo")
