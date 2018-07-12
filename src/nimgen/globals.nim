import os, parsecfg, tables

const
  cCompilerEnv* = "CC"
  cppCompilerEnv* = "CPP"
  defaultCCompiler* = "gcc"
  defaultCppCompiler* = "g++"

var
  gDoneRecursive*: seq[string] = @[]
  gDoneInline*: seq[string] = @[]

  gProjectDir* = ""
  gConfig*: Config
  gFilter* = ""
  gQuotes* = true
  gCppCompiler* = getEnv(cppCompilerEnv, defaultCCompiler)
  gCCompiler* = getEnv(cCompilerEnv, defaultCppCompiler)
  gOutput* = ""
  gIncludes*: seq[string] = @[]
  gExcludes*: seq[string] = @[]
  gRenames* = initTable[string, string]()
  gWildcards* = newConfig()

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

