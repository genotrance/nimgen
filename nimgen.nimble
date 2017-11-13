# Package

version       = "0.1.0"
author        = "genotrance"
description   = "c2nim helper to simpilfy and automate the wrapping of C libraries"
license       = "MIT"

skipDirs = @["tests"]

# Dependencies

requires "nim >= 0.16.0", "c2nim >= 0.9.13"

bin = @["nimgen"]

task test, "Test nimgen":
    exec "nim e tests/nimgentest.nims"
