# Package

version       = "0.2.3"
author        = "genotrance"
description   = "c2nim helper to simplify and automate the wrapping of C libraries"
license       = "MIT"

skipDirs = @["tests"]

# Dependencies

requires "nim >= 0.17.0", "c2nim >= 0.9.13"

bin = @["nimgen"]

task test, "Test nimgen":
    exec "nim e tests/nimgentest.nims"
