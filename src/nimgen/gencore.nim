import os, regex, sequtils, strutils

import file, globals

proc addEnv*(str: string): string =
  var newStr = str

  if "$output" in newStr or "${output}" in newStr:
    newStr = newStr % ["output", gOutput]

  for pair in envPairs():
    if pair.key.len() == 0:
      continue

    if ("$" & pair.key) in newStr or ("${" & pair.key & "}") in newStr:
      newStr = newStr % [pair.key, pair.value.string]

  return newStr

proc compile*(flags: string, dir="", file=""): string =
  var data = ""

  proc fcompile(file: string): string =
    return "{.compile: \"$#\".}" % file.replace("\\", "/")

  proc dcompile(dir: string) =
    for f in walkFiles(dir):
      data &= fcompile(f) & "\n"

  if dir != "":
    if dir.contains("*") or dir.contains("?"):
      dcompile(dir)
    elif dirExists(dir):
      if flags.contains("cpp"):
        for i in @["*.C", "*.cpp", "*.c++", "*.cc", "*.cxx"]:
          dcompile(dir / i)
      else:
        dcompile(dir / "*.c")

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
