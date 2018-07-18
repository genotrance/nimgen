import os, parsecfg, regex, strutils, tables

import c2nim, external, file, fileops, gencore, globals

proc `[]`*(table: OrderedTableRef[string, string], key: string): string =
  ## Gets table values with env vars inserted
  tables.`[]`(table, key).addEnv

proc getKey(ukey: string): tuple[key: string, val: bool] =
  var kv = ukey.replace(re"\..*", "").split("-", 1)
  if kv.len() == 1:
    kv.add("")

  if kv[1] == "":
    return (kv[0], true)

  for ostyp in kv[1].split(","):
    if (ostyp == "win" and defined(Windows)) or
       (ostyp == "lin" and defined(Linux)) or
       ((ostyp == "osx" or ostyp == "mac") and defined(MacOSX)):
      return (kv[0], true)

  return (kv[0], false)

proc runFile*(file: string, cfgin: OrderedTableRef = newOrderedTable[string, string]()) =
  var
    cfg = cfgin
    sfile = search(file)

  if sfile in gDoneRecursive:
    return

  if sfile.len() != 0:
    echo "Processing " & sfile
    gDoneRecursive.add(sfile)

  for pattern in gWildcards.keys():
    var m: RegexMatch
    let pat = pattern.replace(".", "\\.").replace("*", ".*").replace("?", ".?")
    if file.find(toPattern(pat), m):
      echo "  Appending keys for wildcard " & pattern
      for key in gWildcards[pattern].keys():
        cfg[key & "." & pattern] = gWildcards[pattern][key]

  var
    srch = ""

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
        writeFile(file, cfg[act])
        if file in gExcludes:
          gExcludes.delete(gExcludes.find(file))
        sfile = search(file)
        gDoneRecursive.add(sfile)
      elif action in @["prepend", "append", "replace", "comment",
                       "rename", "compile", "dynlib", "pragma",
                       "pipe"] and sfile != "":
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
      elif action == "search":
        srch = act

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

    if not noprocess:
      let outfile = getNimout(sfile)
      c2nim(file, outfile, c2nimConfig)

      if c2nimConfig.recurse:
        var
          cfg = newOrderedTable[string, string]()
          incls = getIncls(sfile)
          incout = ""

        for name, value in c2nimConfig.fieldPairs:
          when value is string:
            cfg[name] = value
          when value is bool:
            cfg[name] = $value

        for i in c2nimConfig.dynlib:
          cfg["dynlib." & i] = i

        for inc in incls:
          runFile(inc, cfg)
          incout &= "import $#\n" % inc.search().getNimout()[0 .. ^5]

        if incout.len() != 0:
          prepend(outfile, incout)

    if reset:
      gitCheckout(sfile)

proc runCfg*(cfg: string) =
  if not fileExists(cfg):
    echo "Config doesn't exist: " & cfg
    quit(1)

  gProjectDir = parentDir(cfg.expandFilename()).sanitizePath

  gConfig = loadConfig(cfg)

  if gConfig.hasKey("n.global"):
    if gConfig["n.global"].hasKey("output"):
      gOutput = gConfig["n.global"]["output"].sanitizePath
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

    if gConfig["n.global"].hasKey("cpp_compiler"):
      gCppCompiler = gConfig["n.global"]["cpp_compiler"]
    else:
      # Reset on a per project basis
      gCppCompiler = getEnv(cppCompilerEnv, defaultCppCompiler)

    if gConfig["n.global"].hasKey("c_compiler"):
      gCCompiler = gConfig["n.global"]["c_compiler"]
    else:
      # Reset on a per project basis
      gCCompiler = getEnv(cCompilerEnv, defaultCCompiler)

    gCppCompiler = gCppCompiler.quoteShell
    gCCompiler = gCCompiler.quoteShell

    if gConfig["n.global"].hasKey("filter"):
      gFilter = gConfig["n.global"]["filter"]
    if gConfig["n.global"].hasKey("quotes"):
      if gConfig["n.global"]["quotes"] == "false":
        gQuotes = false

  if gConfig.hasKey("n.include"):
    for inc in gConfig["n.include"].keys():
      gIncludes.add(inc.addEnv().sanitizePath)

  if gConfig.hasKey("n.exclude"):
    for excl in gConfig["n.exclude"].keys():
      gExcludes.add(excl.addEnv().sanitizePath)

  if gConfig.hasKey("n.prepare"):
    for prep in gConfig["n.prepare"].keys():
      let (key, val) = getKey(prep)
      if val == true:
        let prepVal = gConfig["n.prepare"][prep]
        if key == "download":
          downloadUrl(prepVal)
        elif key == "extract":
          extractZip(prepVal)
        elif key == "git":
          gitRemotePull(prepVal)
        elif key == "gitremote":
          gitRemotePull(prepVal, false)
        elif key == "gitsparse":
          gitSparseCheckout(prepVal)
        elif key == "execute":
          discard execProc(prepVal)
        elif key == "copy":
          doCopy(prepVal)

  if gConfig.hasKey("n.wildcard"):
    var wildcard = ""
    for wild in gConfig["n.wildcard"].keys():
      let (key, val) = getKey(wild)
      if val == true:
        if key == "wildcard":
          wildcard = gConfig["n.wildcard"][wild]
        else:
          gWildcards.setSectionKey(wildcard, wild,
                                   gConfig["n.wildcard"][wild])

  for file in gConfig.keys():
    if file in @["n.global", "n.include", "n.exclude",
                 "n.prepare", "n.wildcard", "n.post"]:
      continue

    if file == "n.sourcefile":
      for pattern in gConfig["n.sourcefile"].keys():
        for file in walkFiles(pattern.addEnv):
          runFile(file)
    else:
      runFile(file, gConfig[file])

  if gConfig.hasKey("n.post"):
    for post in gConfig["n.post"].keys():
      let (key, val) = getKey(post)
      if val == true:
        let postVal = gConfig["n.post"][post]
        if key == "reset":
          gitReset()
        elif key == "execute":
          discard execProc(postVal)
