import os, ospaths, pegs, regex, strutils, tables

import globals

# ###
# File loction

proc getNimout*(file: string, rename=true): string =
  result = file.splitFile().name.replace(re"[\-\.]", "_") & ".nim"
  if gOutput != "":
    result = gOutput/result

  if not rename:
    return

  if gRenames.hasKey(file):
    result = gRenames[file]

  if not dirExists(parentDir(result)):
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
      result = inc/file
      if fileExists(result) or dirExists(result):
        found = true
        break
    if not found:
      echo "File doesn't exist: " & file
      quit(1)

  # Only keep relative directory
  return result.multiReplace([("\\", $DirSep), ("//", $DirSep), (gProjectDir & $DirSep, "")])

# ###
# Loading / unloading

proc openRetry*(file: string, mode: FileMode = fmRead): File =
  while true:
    try:
      result = open(file, mode)
      break
    except IOError:
      sleep(100)

template withFile*(file: string, body: untyped): untyped =
  if fileExists(file):
    var f = openRetry(file)

    var contentOrig = f.readAll()
    f.close()
    var content {.inject.} = contentOrig

    body

    if content != contentOrig:
      f = openRetry(file, fmWrite)
      write(f, content)
      f.close()
  else:
    echo "Missing file " & file

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

  gRenames[file] = gOutput/newname
