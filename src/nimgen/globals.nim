import os, parsecfg, tables

const
  cCompilerEnv* = "CC"
  cppCompilerEnv* = "CPP"
  defaultCCompiler* = "gcc"
  defaultCppCompiler* = "g++"

var
  # Config
  gConfig*: Config
  gExcludes*: seq[string] = @[]
  gIncludes*: seq[string] = @[]
  gRenames* = initTable[string, string]()
  gWildcards* = newConfig()

  # n.global
  gOutput* = "."
  gQuotes* = true
  gFilter* = ""
  gCppCompiler* = getEnv(cppCompilerEnv, defaultCCompiler)
  gCCompiler* = getEnv(cCompilerEnv, defaultCppCompiler)

  # State tracking
  gGitCheckout* = ""
  gGitOutput* = ""
  gProjectDir* = ""
  gCompile*: seq[string] = @[]
  gDoneInline*: seq[string] = @[]
  gDoneRecursive*: seq[string] = @[]

type
  c2nimConfigObj* = object
    flags*, ppflags*: string
    recurse*, inline*, preprocess*, ctags*, defines*: bool
    dynlib*, compile*, pragma*: seq[string]

const gDoc* = """
Nimgen is a helper for c2nim to simpilfy and automate the wrapping of C libraries

Usage:
  nimgen [options] <file.cfg>...

Options:
  -f  delete all artifacts and regenerate
"""

