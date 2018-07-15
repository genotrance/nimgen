import os, osproc, regex, ropes, streams, strutils

import globals

proc execProc*(cmd: string): string =
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

proc extractZip*(zipfile: string) =
  var cmd = "unzip -o $#"
  if defined(Windows):
    cmd = "powershell -nologo -noprofile -command \"& { Add-Type -A " &
          "'System.IO.Compression.FileSystem'; " &
          "[IO.Compression.ZipFile]::ExtractToDirectory('$#', '.'); }\""

  setCurrentDir(gOutput)
  defer: setCurrentDir(gProjectDir)

  echo "Extracting " & zipfile
  discard execProc(cmd % zipfile)

proc downloadUrl*(url: string) =
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

proc gitReset*() =
  echo "Resetting Git repo"

  setCurrentDir(gOutput)
  defer: setCurrentDir(gProjectDir)

  discard execProc("git reset --hard HEAD")

proc gitCheckout*(file: string) =
  echo "  Resetting " & file

  setCurrentDir(gOutput)
  defer: setCurrentDir(gProjectDir)

  discard execProc("git checkout $#" % file.replace(gOutput & "/", ""))

proc gitRemotePull*(url: string, pull=true) =
  if dirExists(gOutput/".git"):
    if pull:
      gitReset()
    return

  setCurrentDir(gOutput)
  defer: setCurrentDir(gProjectDir)

  echo "Setting up Git repo"
  discard execProc("git init .")
  discard execProc("git remote add origin " & url)

  if pull:
    echo "Checking out artifacts"
    discard execProc("git pull --depth=1 origin master")

proc gitSparseCheckout*(plist: string) =
  let sparsefile = ".git/info/sparse-checkout"
  if fileExists(gOutput/sparsefile):
    gitReset()
    return

  setCurrentDir(gOutput)
  defer: setCurrentDir(gProjectDir)

  discard execProc("git config core.sparsecheckout true")
  writeFile(sparsefile, plist)

  echo "Checking out artifacts"
  discard execProc("git pull --depth=1 origin master")

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
        if sfile in line.multiReplace([("\\", "/"), ("//", "/")]):
          start = true
        if not ("\\" in line) and not ("/" in line) and extractFilename(sfile) in line:
          start = true
      else:
        if start:
          rdata.add(
            line.multiReplace([("_Noreturn", ""), ("(())", ""), ("WINAPI", ""),
                               ("__attribute__", ""), ("extern \"C\"", "")])
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
    var spl = line.split('\t')
    if spl.len() > 4:
      if spl[0] != "main" and spl[3] != "member":
        var fn = ""
        var match: RegexMatch
        if spl[2].find(re"/\^(.*?)\(", match):
          fn = spl[2][match.group(0)[0]]
          fn &= spl[4].replace("signature:", "") & ";"
          fdata &= fn & "\n"

  return fdata
