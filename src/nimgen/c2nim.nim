import os, regex, strutils

when (NimMajor, NimMinor, NimPatch) < (0, 19, 9):
  import ospaths

import external, file, fileops, gencore, globals

const passCBase = """

import os, strutils
# import std/time_t  # To use C "time_t" uncomment this line and use time_t.Time

const sourcePath = currentSourcePath().splitPath.head
"""

proc relativePath(path: string): string =
  if gOutput.len() == 0:
    result = path
  else:
    # multiReplace() bug - #9557
    result = path.replace(gOutput, "")
  return result.multiReplace([("\\", "/"), ("//", "/")])

proc c2nim*(fl, outfile: string, c2nimConfig: c2nimConfigObj) =
  var file = search(fl)
  if file.len() == 0:
    return

  echo "Generating " & outfile

  var cfile = file
  if c2nimConfig.preprocess:
    cfile = "temp-$#.c" % [outfile.extractFilename()]
    writeFileFlush(cfile, runPreprocess(file, c2nimConfig.ppflags, c2nimConfig.flags, c2nimConfig.inline))
  elif c2nimConfig.ctags:
    cfile = "temp-$#.c" % [outfile.extractFilename()]
    writeFileFlush(cfile, runCtags(file))

  if c2nimConfig.defines and (c2nimConfig.preprocess or c2nimConfig.ctags):
    prepend(cfile, getDefines(file, c2nimConfig.inline))

  var
    extflags = ""
    passC = "# " & file & " --> " & outfile & passCBase
    outlib = ""
    outpragma = ""

  for inc in gIncludes:
    if inc.isAbsolute():
      passC &= ("""{.passC: "-I\"$#\"".}""" % [inc.sanitizePath()]) & "\n"
    else:
      passC &= (
        """{.passC: "-I\"" & sourcePath & "$#\"".}""" %
          inc.relativePath()
      ) & "\n"

  for prag in c2nimConfig.pragma:
    outpragma &= "{." & prag & ".}\n"

  let fname = file.splitFile.name.normalize.capitalizeAscii.multiReplace([(".", "_"), ("-", "_")])

  if c2nimConfig.dynlib.len() != 0:
    let
      win = "when defined(Windows):\n"
      lin = "when defined(Linux):\n"
      osx = "when defined(MacOSX):\n"

    var winlib, linlib, osxlib: string = ""
    for dl in c2nimConfig.dynlib:
      let
        lib = "  const dynlib$# = \"$#\"\n" % [fname, dl]
        ext = dl.splitFile().ext

      if ext == ".dll":
        winlib &= lib
      elif ext == ".so":
        linlib &= lib
      elif ext == ".dylib":
        osxlib &= lib

    if winlib != "":
      outlib &= win & winlib & "\n"
    if linlib != "":
      outlib &= lin & linlib & "\n"
    if osxlib != "":
      outlib &= osx & osxlib & "\n"

    if outlib != "":
      extflags &= " --dynlib:dynlib$#" % fname
  else:
    if file.isAbsolute():
      passC &= "const header$# = \"$#\"\n" % [fname, file]
    else:
      passC &= "const header$# = sourcePath / \"$#\"\n" %
        [fname, file.relativePath()]
    extflags = "--header:header$#" % fname
  # Run c2nim on generated file
  var cmd = "c2nim $# $# --out:$# $#" % [c2nimConfig.flags, extflags, outfile, cfile]
  when defined(windows):
    cmd = "cmd /c " & cmd.quoteShell
  discard execProc(cmd)

  if c2nimConfig.preprocess or c2nimConfig.ctags:
    try:
      removeFile(cfile)
    except:
      discard

  # Nim doesn't like {.cdecl.} for type proc()
  freplace(outfile, re"(?m)(.*? = proc.*?)\{.cdecl.\}", "$1")
  freplace(outfile, " {.cdecl.})", ")")

  # Include {.compile.} directives
  for cpl in c2nimConfig.compile:
    prepend(outfile, compile(cpl, c2nimConfig.flags))

  # Add any pragmas
  if outpragma != "":
    prepend(outfile, outpragma)

  # Add header file and include paths
  if passC != "":
    prepend(outfile, passC)

  # Add dynamic library
  if outlib != "":
    prepend(outfile, outlib)
