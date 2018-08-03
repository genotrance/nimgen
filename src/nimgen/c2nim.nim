import os, ospaths, regex, strutils

import external, file, fileops, gencore, globals

template relativePath(path: untyped): untyped =
  path.multiReplace([(gOutput, ""), ("\\", "/"), ("//", "/")])

proc c2nim*(fl, outfile: string, c2nimConfig: c2nimConfigObj) =
  var file = search(fl)
  if file.len() == 0:
    return

  echo "  Generating " & outfile

  # Remove static inline function bodies
  removeStatic(file)

  fixFuncProtos(file)

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
    passC = ""
    outlib = ""
    outpragma = ""

  passC = "import ospaths, strutils\n"

  passC &= """const sourcePath = currentSourcePath().split({'\\', '/'})[0..^2].join("/")""" & "\n"

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

  let fname = file.splitFile().name.multiReplace([(".", "_"), ("-", "_")])

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
      passC &= "const header$# = sourcePath & \"$#\"\n" %
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
  freplace(outfile, re"(?m)(.*? = proc.*?)\{.cdecl.\}", "$#")
  freplace(outfile, " {.cdecl.})", ")")

  # Include {.compile.} directives
  for cpl in c2nimConfig.compile:
    let fcpl = search(cpl)
    if getFileInfo(fcpl).kind == pcFile:
      prepend(outfile, compile(file=fcpl))
    else:
      prepend(outfile, compile(dir=fcpl))

  # Add any pragmas
  if outpragma != "":
    prepend(outfile, outpragma)

  # Add header file and include paths
  if passC != "":
    prepend(outfile, passC)

  # Add dynamic library
  if outlib != "":
    prepend(outfile, outlib)

  # Add back static functions for compilation
  reAddStatic(file)
