import os, regex, sequtils, strutils

import file, globals

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
  if newStr.contains("$") and not newStr.contains("$replace("):
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
        result &= getDefines(sincl)
  withFile(file):
    for def in content.findAll(re"(?m)^(\s*#\s*define\s+[\w\d_]+\s+[\d\-.xf]+)(?:\r|//|/*).*?$"):
      result &= content[def.group(0)[0]] & "\n"
