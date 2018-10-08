# Package

version       = "0.4.0"
author        = "genotrance"
description   = "c2nim helper to simplify and automate the wrapping of C libraries"
license       = "MIT"

bin = @["nimgen"]
srcDir = "src"
skipDirs = @["nimgen", "tests"]

# Dependencies

requires "nim >= 0.17.0", "c2nim >= 0.9.13", "regex <= 0.7.4"

task test, "Test nimgen":
    exec "nim c -r tests/rununittests.nim"
    exec "nim e tests/nimgentest.nims"
