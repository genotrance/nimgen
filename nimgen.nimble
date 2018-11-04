# Package

version       = "0.5.0"
author        = "genotrance"
description   = "c2nim helper to simplify and automate the wrapping of C libraries"
license       = "MIT"

bin = @["nimgen"]
srcDir = "src"
skipDirs = @["tests", "web"]

# Dependencies

requires "nim >= 0.17.0", "c2nim#3ec45c24585ebaed", "regex >= 0.10.0"

task test, "Test nimgen":
    exec "nim c -r tests/rununittests.nim"
    exec "nim e tests/nimgentest.nims"
