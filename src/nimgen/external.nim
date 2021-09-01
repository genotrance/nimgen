import os, osproc, regex, strutils

import globals

proc sanitizePath*(path: string): string =
  path.multiReplace([("\\", "/"), ("//", "/")])

proc execProc*(cmd: string): string =
  var ret: int

  (result, ret) = execCmdEx(cmd)
  if ret != 0:
    echo "Command failed: " & $ret
    echo cmd
    echo result
    quit(1)

proc execAction*(cmd: string): string =
  var ccmd = ""
  when defined(Windows):
    ccmd = "cmd /c " & cmd.replace("/", "\\")
  when defined(Linux) or defined(MacOSX):
    ccmd = "bash -c '" & cmd & "'"

  echo "Running '" & ccmd[0..min(64, len(ccmd)-1)] & "'"
  return execProc(ccmd)

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

  var cmd = if defined(Windows):
    "powershell [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; wget $# -OutFile $#"
  else:
    "curl -Lk $# -o $#"

  if not (ext == ".zip" and fileExists(gOutput/file)):
    echo "Downloading " & file
    discard execProc(cmd % [url, gOutput/file])

  if ext == ".zip":
    extractZip(file)

template setGitDir() =
  setCurrentDir(gGitOutput)
  defer: setCurrentDir(gProjectDir)

proc gitReset*() =
  echo "Resetting " & gGitOutput

  setGitDir()

  let cmd = "git reset --hard"
  while execCmdEx(cmd)[0].contains("Permission denied"):
    sleep(1000)
    echo "  Retrying ..."

proc gitCheckout*(file: string) =
  echo "Resetting " & file

  setGitDir()

  let cmd = "git checkout $#" % file.replace(gGitOutput & "/", "")
  while execCmdEx(cmd)[0].contains("Permission denied"):
    sleep(500)
    echo "  Retrying ..."

proc gitPull() =
  let branch = if gGitBranch != "": gGitBranch else: "master"
  if gGitCheckout.len() != 0:
    echo "Checking out " & gGitCheckout
    discard execProc("git pull --tags origin " & branch)
    discard execProc("git checkout " & gGitCheckout)
    gGitCheckout = ""
  else:
    echo "Pulling repository"
    discard execProc("git pull --depth=1 origin " & branch)

proc gitRemotePull*(url: string, pull=true) =
  if dirExists(gGitOutput/".git"):
    if pull:
      gitReset()
    return

  setGitDir()

  echo "Setting up Git repo: " & url
  discard execProc("git init .")
  discard execProc("git remote add origin " & url)

  if pull:
    gitPull()

proc gitSparseCheckout*(plist: string) =
  let sparsefile = ".git/info/sparse-checkout"
  if fileExists(gGitOutput/sparsefile):
    gitReset()
    return

  setGitDir()

  discard execProc("git config core.sparsecheckout true")
  writeFile(sparsefile, plist)

  gitPull()

proc runPreprocess*(file, ppflags, flags: string, inline: bool): string =
  var
    pproc = if flags.contains("cpp"): gCppCompiler else: gCCompiler
    cmd = "$# -E $# $#" % [pproc, ppflags, file]

  for inc in gIncludes:
    cmd &= " -I " & inc.quoteShell

  # Run preprocessor
  var data = execProc(cmd)

  # Include content only from file
  var
    rdata: seq[string] = @[]
    start = false
    sfile = file.sanitizePath

  if inline:
    sfile = sfile.parentDir()
  for line in data.splitLines():
    if line.strip() != "":
      if line[0] == '#' and not line.contains("#pragma"):
        start = false
        if sfile in line.sanitizePath:
          start = true
        if not ("\\" in line) and not ("/" in line) and extractFilename(sfile) in line:
          start = true
      else:
        if start:
          rdata.add(
            line.multiReplace([("_Noreturn", ""), ("(())", ""), ("WINAPI", ""),
                               ("__attribute__", ""), ("extern \"C\"", "")])
              .replace(re"\(\([_a-z]+?\)\)", "")
              .replace(re"\(\(__format__[\s]*\(__[gnu_]*printf__, [\d]+, [\d]+\)\)\);", ";")
          )
  return rdata.join("\n")

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
