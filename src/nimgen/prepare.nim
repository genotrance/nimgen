import os, osproc, streams, strutils

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

proc gitCheckout*(filename: string) {.used.} =
  echo "Resetting file: $#" % [filename]

  setCurrentDir(gOutput)
  defer: setCurrentDir(gProjectDir)

  let adjustedFile = filename.replace(gOutput & $DirSep, "")

  discard execProc("git checkout $#" % [adjustedFile])

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

proc doCopy*(flist: string) =
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
