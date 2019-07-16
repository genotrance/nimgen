# Package

version       = "0.5.1"
author        = "genotrance"
description   = "c2nim helper to simplify and automate the wrapping of C libraries"
license       = "MIT"

bin = @["nimgen"]
srcDir = "src"
skipDirs = @["nimgen", "tests", "web"]

# Dependencies

requires "nim >= 0.19.0", "regex >= 0.10.0"

when NimVersion < "0.20.0":
  requires "c2nim#8f1705509084ae47319f6fcfb131e515b134e0f1"
else:
  requires "c2nim >= 0.9.14"

task test, "Test nimgen":
    exec "nim c -r tests/rununittests.nim"
    exec "nim e tests/nimgentest.nims"
