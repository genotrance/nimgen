import os, parsecfg, regex, strutils, tables

import c2nim, external, file, fileops, gencore, globals

proc `[]`*(table: OrderedTableRef[string, string], key: string): string =
  ## Gets table values with env vars inserted
  tables.`[]`(table, key).addEnv

proc getKey(ukey: string, section = false): tuple[key: string, val: bool] =
  var kv = if not section: ukey.replace(re"\..*", "").split("-", 1) else: ukey.split("-", 1)
  if kv.len() == 1:
    kv.add("")

  if kv[1] == "":
    return (kv[0], true)

  for ostyp in kv[1].split("-"):
    if (ostyp == "win" and defined(Windows)) or
       (ostyp == "lin" and defined(Linux)) or
       ((ostyp == "osx" or ostyp == "mac") and defined(MacOSX)) or
       (ostyp == "unix" and (defined(Linux) or defined(MacOSX))):
      return (kv[0], true)

  return (kv[0], false)

proc runFile*(file: string, cfgin: OrderedTableRef = newOrderedTable[string, string]()) =
  var
    cfg = cfgin
    sfile = search(file)
    nowildcard = false

  if sfile in gDoneRecursive:
    return

  if sfile.len() != 0:
    echo "Processing " & sfile
    gDoneRecursive.add(sfile)

  for act in cfg.keys():
    let (action, val) = getKey(act)
    if val == true and action == "nowildcard" and cfg[act] == "true":
      nowildcard = true
      break

  if not nowildcard:
    for pattern in gWildcards.keys():
      var m: RegexMatch
      let pat = pattern.replace(".", "\\.").replace("*", ".*").replace("?", ".?")
      if file.find(toPattern(pat), m):
        echo "  Appending keys for wildcard " & pattern
        for key in gWildcards[pattern].keys():
          cfg[key & "." & pattern] = gWildcards[pattern][key]

  var
    srch = ""
    rgx = ""

    c2nimConfig = c2nimConfigObj(
      flags: "--stdcall", ppflags: "",
      recurse: false, inline: false, preprocess: false, ctags: false, defines: false,
      dynlib: @[], compile: @[], pragma: @[]
    )

  for act in cfg.keys():
    let (action, val) = getKey(act)
    if val == true:
      if action == "create":
        echo "Creating " & file
        createDir(file.splitPath().head)
        writeFileFlush(file, cfg[act])
        if file in gExcludes:
          gExcludes.delete(gExcludes.find(file))
        sfile = file
        gDoneRecursive.add(sfile)
      elif action in @["prepend", "append", "replace", "move", "comment",
                       "rename", "compile", "dynlib", "pragma", "pipe"] and
          sfile != "":
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
          elif rgx != "":
            freplace(sfile, toPattern(cfg[rgx]), cfg[act])
        elif action == "move":
          if srch != "":
            move(sfile, cfg[srch], cfg[act])
          elif rgx != "":
            move(sfile, toPattern(cfg[rgx]), cfg[act])
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
        elif action == "pipe":
          pipe(sfile, cfg[act])
        srch = ""
        rgx = ""
      elif action == "search":
        srch = act
      elif action == "regex":
        rgx = act

  if file.splitFile().ext != ".nim":
    var
      noprocess = false
      reset = false

    for act in cfg.keys():
      let (action, val) = getKey(act)
      if val == true:
        if cfg[act] == "true":
          if action == "recurse":
            c2nimConfig.recurse = true
          elif action == "inline":
            c2nimConfig.inline = true
          elif action == "preprocess":
            c2nimConfig.preprocess = true
          elif action == "ctags":
            c2nimConfig.ctags = true
          elif action == "defines":
            c2nimConfig.defines = true
          elif action == "noprocess":
            noprocess = true
          elif action == "reset":
            reset = true
        elif action == "flags":
          c2nimConfig.flags = cfg[act]
        elif action == "ppflags":
          c2nimConfig.ppflags = cfg[act]

    if c2nimConfig.recurse and c2nimConfig.inline:
      echo "Cannot use recurse and inline simultaneously"
      quit(1)

    removeStatic(sfile)
    fixFuncProtos(sfile)

    let outfile = getNimout(sfile)
    var incout = ""
    if c2nimConfig.recurse or c2nimConfig.inline:
      var
        cfg = newOrderedTable[string, string]()
        incls = getIncls(sfile)

      for name, value in c2nimConfig.fieldPairs:
        when value is string:
          cfg[name] = value
        when value is bool:
          cfg[name] = $value

      for i in c2nimConfig.dynlib:
        cfg["dynlib." & i] = i

      if c2nimConfig.inline:
        cfg["noprocess"] = "true"

      for inc in incls:
        runFile(inc, cfg)
        if c2nimConfig.recurse:
          incout &= "import $#\n" % inc.search().getNimout()[0 .. ^5]

    if not noprocess:
      c2nim(file, outfile, c2nimConfig)

      if c2nimConfig.recurse and incout.len() != 0:
        prepend(outfile, incout)

    if reset:
      gitCheckout(sfile)

proc setOutputDir(dir: string) =
  gOutput = dir.sanitizePath
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

  gGitOutput = gOutput

proc runCfg*(cfg: string) =
  if not fileExists(cfg):
    echo "Config doesn't exist: " & cfg
    quit(1)

  gProjectDir = parentDir(cfg.expandFilename()).sanitizePath

  gConfig = loadConfig(cfg)
  gCppCompiler = getEnv(cppCompilerEnv, defaultCppCompiler).quoteShell
  gCCompiler = getEnv(cCompilerEnv, defaultCCompiler).quoteShell
  gGitOutput = gOutput

  for section in gConfig.keys():
    let (sname, sval) = getKey(section, true)
    if not sval:
      continue

    case sname:
      of "n.global":
        for glob in gConfig[section].keys():
          let (key, val) = getKey(glob)
          if val == true:
            let globVal = gConfig[section][glob]
            case key:
              of "output":
                setOutputDir(globVal)
              of "cpp_compiler":
                gCppCompiler = globVal.quoteShell
              of "c_compiler":
                gCCompiler = globVal.quoteShell
              of "filter":
                gFilter = globVal
              of "quotes":
                if globVal == "false":
                  gQuotes = false

      of "n.include":
        for inc in gConfig[section].keys():
          gIncludes.add(inc.addEnv().sanitizePath)

      of "n.exclude":
        for excl in gConfig[section].keys():
          gExcludes.add(excl.addEnv().sanitizePath)

      of "n.prepare":
        for prep in gConfig[section].keys():
          let (key, val) = getKey(prep)
          if val == true:
            let prepVal = gConfig[section][prep]
            case key:
              of "download":
                downloadUrl(prepVal)
              of "extract":
                extractZip(prepVal)
              of "gitcheckout":
                gGitCheckout = prepVal
              of "gitbranch":
                gGitBranch = prepVal
              of "gitoutput":
                gGitOutput = gOutput/prepVal
                createDir(gGitOutput)
              of "git":
                gitRemotePull(prepVal)
              of "gitremote":
                gitRemotePull(prepVal, false)
              of "gitsparse":
                gitSparseCheckout(prepVal)
              of "execute":
                discard execAction(prepVal)
              of "copy":
                doCopy(prepVal)

      of "n.wildcard":
        var wildcard = ""
        for wild in gConfig[section].keys():
          let (key, val) = getKey(wild)
          if val == true:
            if key == "wildcard":
              wildcard = gConfig[section][wild]
            else:
              gWildcards.setSectionKey(wildcard, wild,
                                      gConfig[section][wild])

      of "n.sourcefile":
        for pattern in gConfig[section].keys():
          for file in walkFiles(pattern.addEnv):
            runFile(file)

      of "n.post":
        for post in gConfig[section].keys():
          let (key, val) = getKey(post)
          if val == true:
            let postVal = gConfig[section][post]
            case key:
              of "gitoutput":
                gGitOutput = gOutput/postVal
              of "reset":
                gitReset()
              of "execute":
                discard execAction(postVal)

      else:
        runFile(section, gConfig[section])

let gHelp = """
Nimgen is a helper for c2nim to simplify and automate the wrapping of C libraries

Usage:
  nimgen [options] file.cfg|file.h ...

Params:
  -C<compile>  add compile entry       *
  -E<exclude>  add n.exclude entry     *
  -F<flags>    set c2nim flags         *
  -I<include>  add n.include dir       *
  -O<outdir>   set output directory
  -P<ppflags>  set preprocessor flags  *

Options:
  -c           set ctags = true
  -d           set defines = true
  -i           set inline = true
  -n           set noprocess = true
  -p           set preprocess = true
  -r           set recurse = true

Editing:
  -a<append>   append string           *
  -e<prepend>  prepend string          *
  -l<replace>  replace string          *
  -o#lines     comment X lines         *
  -s<search>   search string           *
  -x<regex>    regex search string     *

* supports multiple instances
"""

proc runCli*() =
  var
    cfg = newOrderedTable[string, string]()
    files: seq[string]
    uniq = 1

  gProjectDir = getCurrentDir().sanitizePath
  for param in commandLineParams():
    let flag = if param.len() <= 2: param else: param[0..<2]

    if fileExists(param):
      if param.splitFile().ext.toLowerAscii() == ".cfg":
        runCfg(param)
      else:
        files.add(param)

    elif flag == "-C":
      cfg["compile." & $uniq] = param[2..^1]
    elif flag == "-E":
      gExcludes.add(param[2..^1].addEnv().sanitizePath)
    elif flag == "-F":
      if cfg.hasKey("flags"):
        cfg["flags"] = cfg["flags"] & " " & param[2..^1]
      else:
        cfg["flags"] = param[2..^1]
    elif flag == "-I":
      gIncludes.add(param[2..^1].addEnv().sanitizePath)
    elif flag == "-O":
      setOutputDir(param[2..^1])
    elif flag == "-P":
      if cfg.hasKey("ppflags"):
        cfg["ppflags"] = cfg["ppflags"] & " " & param[2..^1]
      else:
        cfg["ppflags"] = param[2..^1]

    elif flag == "-c":
      cfg["ctags"] = "true"
    elif flag == "-d":
      cfg["defines"] = "true"
    elif flag == "-i":
      cfg["inline"] = "true"
    elif flag == "-n":
      cfg["noprocess"] = "true"
    elif flag == "-p":
      cfg["preprocess"] = "true"
    elif flag == "-r":
      cfg["recurse"] = "true"

    elif flag == "-a":
      cfg["append." & $uniq] = param[2..^1]
    elif flag == "-e":
      cfg["prepend." & $uniq] = param[2..^1]
    elif flag == "-l":
      cfg["replace." & $uniq] = param[2..^1]
    elif flag == "-o":
      cfg["comment." & $uniq] = param[2..^1]
    elif flag == "-s":
      cfg["search." & $uniq] = param[2..^1]
    elif flag == "-x":
      cfg["regex." & $uniq] = param[2..^1]

    elif param == "-h" or param == "-?" or param == "--help":
      echo gHelp
      quit(0)

    uniq += 1

  for file in files:
    runFile(file, cfg)