import os, pegs, regex, strutils, tables

when (NimMajor, NimMinor, NimPatch) < (0, 19, 9):
  import ospaths

import globals, external

# ###
# File loction

proc getNimout*(file: string, rename=true): string =
  result = file.splitFile().name.multiReplace([("-", "_"), (".", "_")]) & ".nim"
  if gOutput != "":
    result = gOutput & "/" & result

  if not rename:
    return

  if gRenames.hasKey(file):
    result = gRenames[file]

  createDir(parentDir(result))

proc exclude*(file: string): bool =
  for excl in gExcludes:
    if excl in file:
      return true
  return false

proc search*(file: string): string =
  if exclude(file):
    return ""

  result = file
  if file.splitFile().ext == ".nim":
    result = getNimout(file)
  elif not fileExists(result) and not dirExists(result):
    var found = false
    for inc in gIncludes:
      result = inc & "/" & file
      if fileExists(result) or dirExists(result):
        found = true
        break
    if not found:
      echo "File doesn't exist: " & file
      quit(1)

  # Only keep relative directory
  return result.sanitizePath.replace(gProjectDir & "/", "")

proc rename*(file: string, renfile: string) =
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

  gRenames[file] = gOutput & "/" & newname

# ###
# Actions

proc openRetry*(file: string, mode: FileMode = fmRead): File =
  while true:
    try:
      result = open(file, mode)
      break
    except IOError:
      sleep(100)

template writeFileFlush*(file, content: string): untyped =
  let f = openRetry(file, fmWrite)
  f.write(content)
  f.flushFile()
  f.close()

template withFile*(file: string, body: untyped): untyped =
  if fileExists(file):
    var f = openRetry(file)

    var contentOrig = f.readAll()
    f.close()
    var content {.inject.} = contentOrig

    body

    if content != contentOrig:
      writeFileFlush(file, content)
  else:
    echo "Missing file " & file

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
