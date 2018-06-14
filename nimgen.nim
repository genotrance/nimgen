import nre, os, ospaths, osproc, parsecfg, pegs, ropes, sequtils, streams, strutils, tables

var
  gDoneRecursive: seq[string] = @[]
  gDoneInline: seq[string] = @[]

  gConfig: Config
  gFilter = ""
  gQuotes = true
  gCppCompiler = "g++"
  gCCompiler = "gcc"
  gOutput = ""
  gIncludes: seq[string] = @[]
  gExcludes: seq[string] = @[]
  gRenames = initTable[string, string]()
  gWildcards = newConfig()

type
  c2nimConfigObj = object
    flags, ppflags: string
    recurse, inline, preprocess, ctags, defines: bool
    dynlib, compile, pragma: seq[string]

const DOC = """
Nimgen is a helper for c2nim to simpilfy and automate the wrapping of C libraries

Usage:
  nimgen [options] <file.cfg>...

Options:
  -f  delete all artifacts and regenerate
"""

# ###
# Helpers

proc execProc(cmd: string): string =
  result = ""
  var
    p = startProcess(cmd, options = {poStdErrToStdOut, poUsePath, poEvalCommand})

    outp = outputStream(p)
    line = newStringOfCap(120).TaintedString

  while true:
    if outp.readLine(line):
      result.add(line)
      result.add("\n")
    elif not running(p): break

  var x = p.peekExitCode()
  if x != 0:
    echo "Command failed: " & $x
    echo cmd
    echo result
    quit(1)

proc extractZip(zipfile: string) =
  var cmd = "unzip -o $#"
  if defined(Windows):
    cmd = "powershell -nologo -noprofile -command \"& { Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::ExtractToDirectory('$#', '.'); }\""

  setCurrentDir(gOutput)
  defer: setCurrentDir("..")

  echo "Extracting " & zipfile
  discard execProc(cmd % zipfile)

proc downloadUrl(url: string) =
  let
    file = url.extractFilename()
    ext = file.splitFile().ext.toLowerAscii()

  var cmd = "curl $# -o $#"
  if defined(Windows):
    cmd = "powershell wget $# -OutFile $#"

  if not (ext == ".zip" and fileExists(gOutput/file)):
    echo "Downloading " & file
    discard execProc(cmd % [url, gOutput/file])

  if ext == ".zip":
    extractZip(file)

proc gitReset() =
  echo "Resetting Git repo"

  setCurrentDir(gOutput)
  defer: setCurrentDir("..")

  discard execProc("git reset --hard HEAD")

proc gitRemotePull(url: string, pull=true) =
  if dirExists(gOutput/".git"):
    if pull:
      gitReset()
    return

  setCurrentDir(gOutput)
  defer: setCurrentDir("..")

  echo "Setting up Git repo"
  discard execProc("git init .")
  discard execProc("git remote add origin " & url)

  if pull:
    echo "Checking out artifacts"
    discard execProc("git pull --depth=1 origin master")

proc gitSparseCheckout(plist: string) =
  let sparsefile = ".git/info/sparse-checkout"
  if fileExists(gOutput/sparsefile):
    gitReset()
    return

  setCurrentDir(gOutput)
  defer: setCurrentDir("..")

  discard execProc("git config core.sparsecheckout true")
  writeFile(sparsefile, plist)

  echo "Checking out artifacts"
  discard execProc("git pull --depth=1 origin master")

proc doCopy(flist: string) =
  for pair in flist.split(","):
    let spl = pair.split("=")
    if spl.len() != 2:
      echo "Bad copy syntax: " & flist
      quit(1)

    let
      lfile = spl[0].strip()
      rfile = spl[1].strip()

    copyFile(lfile, rfile)
    echo "Copied $# to $#" % [lfile, rfile]

proc getKey(ukey: string): tuple[key: string, val: bool] =
  var kv = ukey.replace(re"\..*", "").split("-", 1)
  if kv.len() == 1:
    kv.add("")

  if (kv[1] == "") or
    (kv[1] == "win" and defined(Windows)) or
    (kv[1] == "lin" and defined(Linux)) or
    (kv[1] == "osx" and defined(MacOSX)):
    return (kv[0], true)

  return (kv[0], false)

# ###
# File loction

proc getNimout(file: string, rename=true): string =
  result = file.splitFile().name.replace(re"[\-\.]", "_") & ".nim"
  if gOutput != "":
    result = gOutput/result

  if not rename:
    return

  if gRenames.hasKey(file):
    result = gRenames[file]

  if not dirExists(parentDir(result)):
    createDir(parentDir(result))

proc exclude(file: string): bool =
  for excl in gExcludes:
    if excl in file:
      return true
  return false

proc search(file: string): string =
  if exclude(file):
    return ""

  result = file
  if file.splitFile().ext == ".nim":
    result = getNimout(file)
  elif not fileExists(result) and not dirExists(result):
    var found = false
    for inc in gIncludes:
      result = inc/file
      if fileExists(result) or dirExists(result):
        found = true
        break
    if not found:
      echo "File doesn't exist: " & file
      quit(1)

  return result.replace(re"[\\/]", $DirSep)

# ###
# Loading / unloading

template withFile(file: string, body: untyped): untyped =
  if fileExists(file):
    var f: File
    while true:
      try:
        f = open(file)
        break
      except:
        sleep(100)

    var contentOrig = f.readAll()
    f.close()
    var content {.inject.} = contentOrig

    body

    if content != contentOrig:
      var f = open(file, fmWrite)
      write(f, content)
      f.close()
  else:
    echo "Missing file " & file

# ###
# Manipulating content

proc prepend(file: string, data: string, search="") =
  withFile(file):
    if search == "":
      content = data & content
    else:
      let idx = content.find(search)
      if idx != -1:
        content = content[0..<idx] & data & content[idx..<content.len()]

proc append(file: string, data: string, search="") =
  withFile(file):
    if search == "":
      content &= data
    else:
      let idx = content.find(search)
      let idy = idx + search.len()
      if idx != -1:
        content = content[0..<idy] & data & content[idy..<content.len()]

proc freplace(file: string, pattern: string, repl="") =
  withFile(file):
    if pattern in content:
      content = content.replace(pattern, repl)

proc freplace(file: string, pattern: Regex, repl="") =
  withFile(file):
    if content.find(pattern).isSome():
      if "$#" in repl:
        for m in content.findIter(pattern):
          content = content.replace(m.match, repl % m.captures[0])
      else:
        content = content.replace(pattern, repl)

proc comment(file: string, pattern: string, numlines: string) =
  let
    ext = file.splitFile().ext.toLowerAscii()
    cmtchar = if ext == ".nim": "#" else: "//"

  withFile(file):
    var
      idx = content.find(pattern)
      num = 0

    try:
      num = numlines.parseInt()
    except ValueError:
      echo "Bad comment value, should be integer: " & numlines
    if idx != -1:
      for i in 0 .. num-1:
        if idx >= content.len():
          break
        content = content[0..<idx] & cmtchar & content[idx..<content.len()]
        while idx < content.len():
          idx += 1
          if content[idx] == '\L':
            idx += 1
            break

proc rename(file: string, renfile: string) =
  if file.splitFile().ext == ".nim":
    return

  var
    nimout = getNimout(file, false)
    newname = renfile.replace("$nimout", extractFilename(nimout))

  if newname =~ peg"(!\$.)*{'$replace'\s*'('\s*{(!\)\S)+}')'}":
    var final = nimout.extractFilename()
    for entry in matches[1].split(","):
      let spl = entry.split("=")
      if spl.len() != 2:
        echo "Bad replace syntax: " & renfile
        quit(1)

      let
        srch = spl[0].strip()
        repl = spl[1].strip()

      final = final.replace(srch, repl)
    newname = newname.replace(matches[0], final)

  gRenames[file] = gOutput/newname

proc compile(dir="", file=""): string =
  proc fcompile(file: string): string =
    return "{.compile: \"$#\".}" % file.replace("\\", "/")

  var data = ""
  if dir != "" and dirExists(dir):
    for f in walkFiles(dir / "*.c"):
      data &= fcompile(f) & "\n"

  if file != "" and fileExists(file):
    data &= fcompile(file) & "\n"

  return data

proc fixFuncProtos(file: string) =
  withFile(file):
    for fp in content.findIter(re"(?m)(^.*?)[ ]*\(\*(.*?)\((.*?)\)\)[ \r\n]*\((.*?[\r\n]*.*?)\);"):
      var tdout = "typedef $# (*type_$#)($#);\n" % [fp.captures[0], fp.captures[1], fp.captures[3]] &
        "type_$# $#($#);" % [fp.captures[1], fp.captures[1], fp.captures[2]]
      content = content.replace(fp.match, tdout)

# ###
# Convert to Nim

proc getIncls(file: string, inline=false): seq[string] =
  result = @[]
  if inline and file in gDoneInline:
    return

  withFile(file):
    for f in content.findIter(re"(?m)^\s*#\s*include\s+(.*?)$"):
      var inc = f.captures[0].strip()
      if ((gQuotes and inc.contains("\"")) or (gFilter != "" and gFilter in inc)) and (not exclude(inc)):
        result.add(
          inc.replace(re"""[<>"]""", "").replace(re"\/[\*\/].*$", "").strip())

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

proc getDefines(file: string, inline=false): string =
  result = ""
  if inline:
    var incls = getIncls(file, inline)
    for incl in incls:
      let sincl = search(incl)
      if sincl != "":
        echo "Inlining " & sincl
        result &= getDefines(sincl)
  withFile(file):
    for def in content.findIter(re"(?m)^(\s*#\s*define\s+[\w\d_]+\s+[\d\-.xf]+)(?:\r|//|/*).*?$"):
      result &= def.captures[0] & "\n"

proc runPreprocess(file, ppflags, flags: string, inline: bool): string =
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

proc runCtags(file: string): string =
  var
    cmd = "ctags -o - --fields=+S+K --c-kinds=p --file-scope=no " & file
    fps = execProc(cmd)
    fdata = ""

  for line in fps.splitLines():
    var spl = line.split(re"\t")
    if spl.len() > 4:
      if spl[0] != "main":
        var fn = ""
        var match = spl[2].find(re"/\^(.*?)\(")
        if match.isSome():
          fn = match.get().captures[0]
          fn &= spl[4].replace("signature:", "") & ";"
          fdata &= fn & "\n"

  return fdata

proc runFile(file: string, cfgin: OrderedTableRef)

proc c2nim(fl, outfile: string, c2nimConfig: c2nimConfigObj) =
  var file = search(fl)
  if file == "":
    return

  if file in gDoneRecursive:
    return

  echo "Processing $# => $#" % [file, outfile]
  gDoneRecursive.add(file)

  fixFuncProtos(file)

  var incout = ""
  if c2nimConfig.recurse:
    var
      incls = getIncls(file)
      cfg = newOrderedTable[string, string]()

    for name, value in c2nimConfig.fieldPairs:
      when value is string:
        cfg[name] = value
      when value is bool:
        cfg[name] = $value

    for i in c2nimConfig.dynlib:
      cfg["dynlib." & i] = i

    for inc in incls:
      runFile(inc, cfg)
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

  passC = "import strutils\n"
  for inc in gIncludes:
    passC &= ("""{.passC: "-I\"" & gorge("nimble path $#").strip() & "/$#\"".}""" % [gOutput, inc]) & "\n"

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
    passC &= "const header$# = \"$#\"\n" % [fname, fl]
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
  freplace(outfile, re"(?m)(.*? = proc.*?){.cdecl.}", "$#")
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

# ###
# Processor

proc runFile(file: string, cfgin: OrderedTableRef) =
  var
    cfg = cfgin
    sfile = search(file)

  for pattern in gWildcards.keys():
    let pat = pattern.replace(".", "\\.").replace("*", ".*").replace("?", ".?")
    if file.find(re(pat)).isSome():
      echo "Appending " & file & " " & pattern
      for key in gWildcards[pattern].keys():
        cfg[key & "." & pattern] = gWildcards[pattern][key]

  var
    srch = ""

    c2nimConfig = c2nimConfigObj(
      flags: "--stdcall", ppflags: "",
      recurse: false, inline: false, preprocess: false, ctags: false, defines: false,
      dynlib: @[], compile: @[], pragma: @[]
    )

  for act in cfg.keys():
    let (action, val) = getKey(act)
    if val == true:
      if action == "create":
        createDir(file.splitPath().head)
        writeFile(file, cfg[act])
      elif action in @["prepend", "append", "replace", "comment", "rename", "compile", "dynlib", "pragma"] and sfile != "":
        if action == "prepend":
          if srch != "":
            prepend(sfile, cfg[act], cfg[srch])
          else:
            prepend(sfile, cfg[act])
        elif action == "append":
          if srch != "":
            append(sfile, cfg[act], cfg[srch])
          else:
            append(sfile, cfg[act])
        elif action == "replace":
          if srch != "":
            freplace(sfile, cfg[srch], cfg[act])
        elif action == "comment":
          if srch != "":
            comment(sfile, cfg[srch], cfg[act])
        elif action == "rename":
          rename(sfile, cfg[act])
        elif action == "compile":
          c2nimConfig.compile.add(cfg[act])
        elif action == "dynlib":
          c2nimConfig.dynlib.add(cfg[act])
        elif action == "pragma":
          c2nimConfig.pragma.add(cfg[act])
        srch = ""
      elif action == "search":
        srch = act

  if file.splitFile().ext != ".nim":
    var noprocess = false

    for act in cfg.keys():
      if cfg[act] == "true":
        if act == "recurse":
          c2nimConfig.recurse = true
        elif act == "inline":
          c2nimConfig.inline = true
        elif act == "preprocess":
          c2nimConfig.preprocess = true
        elif act == "ctags":
          c2nimConfig.ctags = true
        elif act == "defines":
          c2nimConfig.defines = true
        elif act == "noprocess":
          noprocess = true
      elif act == "flags":
        c2nimConfig.flags = cfg[act]
      elif act == "ppflags":
        c2nimConfig.ppflags = cfg[act]

    if c2nimConfig.recurse and c2nimConfig.inline:
      echo "Cannot use recurse and inline simultaneously"
      quit(1)

    if not noprocess:
      c2nim(file, getNimout(sfile), c2nimConfig)

proc runCfg(cfg: string) =
  if not fileExists(cfg):
    echo "Config doesn't exist: " & cfg
    quit(1)

  gConfig = loadConfig(cfg)

  if gConfig.hasKey("n.global"):
    if gConfig["n.global"].hasKey("output"):
      gOutput = gConfig["n.global"]["output"]
      if dirExists(gOutput):
        if "-f" in commandLineParams():
          try:
            removeDir(gOutput)
          except OSError:
            echo "Directory in use: " & gOutput
            quit(1)
        else:
          for f in walkFiles(gOutput/"*.nim"):
            try:
              removeFile(f)
            except OSError:
              echo "Unable to delete: " & f
              quit(1)
      createDir(gOutput)

    if gConfig["n.global"].hasKey("cpp_compiler"):
      gCppCompiler = gConfig["n.global"]["cpp_compiler"]
    if gConfig["n.global"].hasKey("c_compiler"):
      gCCompiler = gConfig["n.global"]["c_compiler"]

    if gConfig["n.global"].hasKey("filter"):
      gFilter = gConfig["n.global"]["filter"]
    if gConfig["n.global"].hasKey("quotes"):
      if gConfig["n.global"]["quotes"] == "false":
        gQuotes = false

  if gConfig.hasKey("n.include"):
    for inc in gConfig["n.include"].keys():
      gIncludes.add(inc)

  if gConfig.hasKey("n.exclude"):
    for excl in gConfig["n.exclude"].keys():
      gExcludes.add(excl)

  if gConfig.hasKey("n.prepare"):
    for prep in gConfig["n.prepare"].keys():
      let (key, val) = getKey(prep)
      if val == true:
        if key == "download":
          downloadUrl(gConfig["n.prepare"][prep])
        elif key == "extract":
          extractZip(gConfig["n.prepare"][prep])
        elif key == "git":
          gitRemotePull(gConfig["n.prepare"][prep])
        elif key == "gitremote":
          gitRemotePull(gConfig["n.prepare"][prep], false)
        elif key == "gitsparse":
          gitSparseCheckout(gConfig["n.prepare"][prep])
        elif key == "execute":
          discard execProc(gConfig["n.prepare"][prep])
        elif key == "copy":
          doCopy(gConfig["n.prepare"][prep])

  if gConfig.hasKey("n.wildcard"):
    var wildcard = ""
    for wild in gConfig["n.wildcard"].keys():
      let (key, val) = getKey(wild)
      if val == true:
        if key == "wildcard":
          wildcard = gConfig["n.wildcard"][wild]
        else:
          gWildcards.setSectionKey(wildcard, wild, gConfig["n.wildcard"][wild])

  for file in gConfig.keys():
    if file in @["n.global", "n.include", "n.exclude", "n.prepare", "n.wildcard"]:
      continue

    runFile(file, gConfig[file])

# ###
# Main loop

for i in commandLineParams():
  if i != "-f":
    runCfg(i)
