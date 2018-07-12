import os, regex, ropes, sequtils, strutils, tables

import file, fileops, globals, prepare

proc addEnv*(str: string): string =
  var newStr = str
  for pair in envPairs():
    try:
      newStr = newStr % [pair.key, pair.value.string]
    except ValueError:
      # Ignore if there are no values to replace. We
      # want to continue anyway
      discard

  try:
    newStr = newStr % ["output", gOutput]
  except ValueError:
    # Ignore if there are no values to replace. We
    # want to continue anyway
    discard

  # if there are still format args, print a warning
  if newStr.contains("${"):
    echo "WARNING: \"", newStr, "\" still contains an uninterpolated value!"

  return newStr

proc compile*(dir="", file=""): string =
  proc fcompile(file: string): string =
    return "{.compile: \"$#\".}" % file.replace("\\", "/")

  var data = ""
  if dir != "" and dirExists(dir):
    for f in walkFiles(dir / "*.c"):
      data &= fcompile(f) & "\n"

  if file != "" and fileExists(file):
    data &= fcompile(file) & "\n"

  return data

proc getIncls*(file: string, inline=false): seq[string] =
  result = @[]
  if inline and file in gDoneInline:
    return

  let curPath = splitFile(expandFileName(file)).dir
  withFile(file):
    for f in content.findAll(re"(?m)^\s*#\s*include\s+(.*?)$"):
      var inc = content[f.group(0)[0]].strip()
      if ((gQuotes and inc.contains("\"")) or (gFilter != "" and gFilter in inc)) and (not exclude(inc)):
        let addInc = inc.replace(re"""[<>"]""", "").replace(re"\/[\*\/].*$", "").strip()
        try:
          # Try searching for a local library. expandFilename will throw
          # OSError if the file does not exist
          let
            finc = expandFileName(curPath / addInc)
            fname = finc.replace(curPath & $DirSep, "")

          if fname.len() > 0:
            # only add if the file is non-empty
            result.add(fname.search())
        except OSError:
          # If it's a system library
          result.add(addInc)

    result = result.deduplicate()

  gDoneInline.add(file)

  if inline:
    var sres = newSeq[string]()
    for incl in result:
      let sincl = search(incl)
      if sincl == "":
        continue

      sres.add(getIncls(sincl, inline))
    result.add(sres)

  result = result.deduplicate()

proc getDefines*(file: string, inline=false): string =
  result = ""
  if inline:
    var incls = getIncls(file, inline)
    for incl in incls:
      let sincl = search(incl)
      if sincl != "":
        echo "Inlining " & sincl
        result &= getDefines(sincl)
  withFile(file):
    for def in content.findAll(re"(?m)^(\s*#\s*define\s+[\w\d_]+\s+[\d\-.xf]+)(?:\r|//|/*).*?$"):
      result &= content[def.group(0)[0]] & "\n"

proc runPreprocess*(file, ppflags, flags: string, inline: bool): string =
  var
    pproc = if flags.contains("cpp"): gCppCompiler else: gCCompiler
    cmd = "$# -E $# $#" % [pproc, ppflags, file]

  for inc in gIncludes:
    cmd &= " -I " & inc

  # Run preprocessor
  var data = execProc(cmd)

  # Include content only from file
  var
    rdata: Rope
    start = false
    sfile = file.replace("\\", "/")

  if inline:
    sfile = sfile.parentDir()
  for line in data.splitLines():
    if line.strip() != "":
      if line[0] == '#' and not line.contains("#pragma"):
        start = false
        if sfile in line.replace("\\", "/").replace("//", "/"):
          start = true
        if not ("\\" in line) and not ("/" in line) and extractFilename(sfile) in line:
          start = true
      else:
        if start:
          rdata.add(
            line.replace("_Noreturn", "")
              .replace("(())", "")
              .replace("WINAPI", "")
              .replace("__attribute__", "")
              .replace("extern \"C\"", "")
              .replace(re"\(\([_a-z]+?\)\)", "")
              .replace(re"\(\(__format__[\s]*\(__[gnu_]*printf__, [\d]+, [\d]+\)\)\);", ";") & "\n"
          )
  return $rdata

proc runCtags*(file: string): string =
  var
    cmd = "ctags -o - --fields=+S+K --c-kinds=+p --file-scope=no " & file
    fps = execProc(cmd)
    fdata = ""

  for line in fps.splitLines():
    var spl = line.split(re"\t")
    if spl.len() > 4:
      if spl[0] != "main" and spl[3] != "member":
        var fn = ""
        var match: RegexMatch
        if spl[2].find(re"/\^(.*?)\(", match):
          fn = spl[2][match.group(0)[0]]
          fn &= spl[4].replace("signature:", "") & ";"
          fdata &= fn & "\n"

  return fdata

template relativePath(path: untyped): untyped =
  path.multiReplace([(gOutput, ""), ("\\", "/"), ("//", "/")])

proc c2nim*(fl, outfile: string, c2nimConfig: c2nimConfigObj): seq[string] =
  var
    incls: seq[string] = @[]
    incout = ""
    file = search(fl)

  if file == "":
    return

  if file in gDoneRecursive:
    return

  echo "Processing $# => $#" % [file, outfile]
  gDoneRecursive.add(file)

  # Remove static inline function bodies
  removeStatic(file)

  fixFuncProtos(file)

  if c2nimConfig.recurse:
    incls = getIncls(file)
    for inc in incls:
      incout &= "import $#\n" % inc.search().getNimout()[0 .. ^5]

  var cfile = file
  if c2nimConfig.preprocess:
    cfile = "temp-$#.c" % [outfile.extractFilename()]
    writeFile(cfile, runPreprocess(file, c2nimConfig.ppflags, c2nimConfig.flags, c2nimConfig.inline))
  elif c2nimConfig.ctags:
    cfile = "temp-$#.c" % [outfile.extractFilename()]
    writeFile(cfile, runCtags(file))

  if c2nimConfig.defines and (c2nimConfig.preprocess or c2nimConfig.ctags):
    prepend(cfile, getDefines(file, c2nimConfig.inline))

  var
    extflags = ""
    passC = ""
    outlib = ""
    outpragma = ""

  passC = "import ospaths, strutils\n"

  for inc in gIncludes:
    if inc.isAbsolute():
      passC &= ("""{.passC: "-I\"$#\"".}""" % [inc]) & "\n"
    else:
      passC &= (
        """{.passC: "-I\"" & currentSourcePath().splitPath().head & "$#\"".}""" %
          inc.relativePath()
      ) & "\n"

  for prag in c2nimConfig.pragma:
    outpragma &= "{." & prag & ".}\n"

  let fname = file.splitFile().name.replace(re"[\.\-]", "_")

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
      passC &= "const header$# = currentSourcePath().splitPath().head & \"$#\"\n" %
        [fname, file.relativePath()]
    extflags = "--header:header$#" % fname

  # Run c2nim on generated file
  var cmd = "c2nim $# $# --out:$# $#" % [c2nimConfig.flags, extflags, outfile, cfile]
  when defined(windows):
    cmd = "cmd /c " & cmd
  discard execProc(cmd)

  if c2nimConfig.preprocess or c2nimConfig.ctags:
    try:
      removeFile(cfile)
    except:
      discard

  # Import nim modules
  if c2nimConfig.recurse:
    prepend(outfile, incout)

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

  return incls
