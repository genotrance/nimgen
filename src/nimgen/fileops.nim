import os, regex, strutils

import external, file

# ###
# Manipulating content

proc prepend*(file: string, data: string, search="") =
  withFile(file):
    if search == "":
      content = data & content
    else:
      let idx = content.find(search)
      if idx != -1:
        content = content[0..<idx] & data & content[idx..<content.len()]

proc pipe*(file: string, command: string) =
  let cmd = command % ["file", file]
  let commandResult = execProc(cmd).strip()
  if commandResult != "":
    withFile(file):
      content = commandResult

proc append*(file: string, data: string, search="") =
  withFile(file):
    if search == "":
      content &= data
    else:
      let idx = content.find(search)
      let idy = idx + search.len()
      if idx != -1:
        content = content[0..<idy] & data & content[idy..<content.len()]

proc freplace*(file: string, pattern: string|Regex, repl="") =
  withFile(file):
    content = content.replace(pattern, repl)

proc move*(file: string, pattern: string|Regex, move: string) =
  var tomove: seq[string] = @[]
  withFile(file):
    when pattern is string:
      tomove.add(pattern)

    when pattern is Regex:
      var ms = content.findAll(pattern)
      for i, m in ms:
        tomove.add(content[m.group(0)[0]])

    content = content.replace(pattern, "")

  for i in tomove:
    append(file, i, move)

proc comment*(file: string, pattern: string, numlines: string) =
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

proc removeStatic*(filename: string) =
  ## Replace static function bodies with a semicolon and commented
  ## out body
  withFile(filename):
    content = content.replace(
      re"(?m)(static inline.*?\))(\s*\{(\s*?.*?$)*?[\n\r]\})",
      proc (m: RegexMatch, s: string): string =
        let funcDecl = s[m.group(0)[0]]
        let body = s[m.group(1)[0]].strip()
        result = ""

        result.add("$#;" % [funcDecl])
        result.add(body.replace(re"(?m)^(.*\n?)", "//$1"))
    )

proc reAddStatic*(filename: string) =
  ## Uncomment out the body and remove the semicolon. Undoes
  ## removeStatic
  withFile(filename):
    content = content.replace(
      re"(?m)(static inline.*?\));(\/\/\s*\{(\s*?.*?$)*?[\n\r]\/\/\})",
      proc (m: RegexMatch, s: string): string =
        let funcDecl = s[m.group(0)[0]]
        let body = s[m.group(1)[0]].strip()
        result = ""

        result.add("$# " % [funcDecl])
        result.add(body.replace(re"(?m)^\/\/(.*\n?)", "$1"))
    )

proc fixFuncProtos*(file: string) =
  withFile(file):
    content = content.replace(re"(?m)(^.*?)[ ]*\(\*(.*?)\((.*?)\)\)[ \r\n]*\((.*?[\r\n]*.*?)\);",
      proc (m: RegexMatch, s: string): string =
        (("typedef $# (*type_$#)($#);\n" % [s[m.group(0)[0]], s[m.group(1)[0]], s[m.group(3)[0]]]) &
         ("type_$# $#($#);" % [s[m.group(1)[0]], s[m.group(1)[0]], s[m.group(2)[0]]]))
    )
