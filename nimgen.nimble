# Package

version       = "0.1.1"
author        = "genotrance"
description   = "c2nim helper to simpilfy and automate the wrapping of C libraries"
license       = "MIT"

skipDirs = @["tests"]

# Dependencies

requires "nim >= 0.16.0", "c2nim >= 0.9.13", "docopt >= 0.6.5"

bin = @["nimgen"]

task test, "Test nimgen":
    exec "nim e tests/nimgentest.nims"
