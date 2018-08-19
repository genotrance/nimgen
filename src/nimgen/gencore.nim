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

proc compile*(cpl, flags: string): string =
  var data = ""

  proc fcompile(file: string): string =
    let fn = file.splitFile().name
    var
      ufn = fn
      uniq = 1
    while ufn in gCompile:
      ufn = fn & $uniq
      uniq += 1

    gCompile.add(ufn)
    if fn == ufn:
      return "{.compile: \"$#\".}" % file.replace("\\", "/")
    else:
      return "{.compile: (\"../$#\", \"$#.o\").}" % [file.replace("\\", "/"), ufn]

  proc dcompile(dir: string) =
    for f in walkFiles(dir):
      data &= fcompile(f) & "\n"

  if cpl.contains("*") or cpl.contains("?"):
    dcompile(cpl)
  else:
    let fcpl = search(cpl)
    if getFileInfo(fcpl).kind == pcFile:
      data &= fcompile(fcpl) & "\n"
    elif getFileInfo(fcpl).kind == pcDir:
      if flags.contains("cpp"):
        for i in @["*.C", "*.cpp", "*.c++", "*.cc", "*.cxx"]:
          dcompile(fcpl / i)
      else:
        dcompile(fcpl / "*.c")

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
