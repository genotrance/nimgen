import nre
import os
import ospaths
import osproc
import parsecfg
import ropes
import sequtils
import streams
import strutils
import tables

var FILES: TableRef[string, string] = newTable[string, string]()
var DONE: seq[string] = @[]

var CONFIG: Config
var FILTER = ""
var OUTPUT = ""
var INCLUDES: seq[string] = @[]
var EXCLUDES: seq[string] = @[]

# ###
# Helpers

proc execProc(cmd: string): string =
    var p = startProcess(cmd, options = {poStdErrToStdOut, poUsePath, poEvalCommand})

    result = ""
    var outp = outputStream(p)
    var line = newStringOfCap(120).TaintedString
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
        quit()

# ###
# File loction

proc getnimout(file: string): string =
    var nimout = file.splitFile().name & ".nim"
    if OUTPUT != "":
        nimout = OUTPUT/nimout
    removeFile(nimout)

    return nimout

proc exclude(file: string): bool =
    for excl in EXCLUDES:
        if excl in file:
            return true
    return false

proc search(file: string): string =
    if exclude(file):
        return ""

    result = file
    if file.splitFile().ext == ".nim":
        result = getnimout(file)
    elif not fileExists(result):
        var found = false
        for inc in INCLUDES:
            result = inc/file
            if fileExists(result):
                found = true
                break
        if not found:
            echo "File doesn't exist: " & file
            quit()

    return result.replace(re"[\\/]", $DirSep)
        
# ###
# Loading / unloading

proc loadfile(file: string) =
    if FILES.hasKey(file):
        return

    FILES[file] = readFile(file)

proc savefile(file: string) =
    try:
        if FILES.hasKey(file):
            writeFile(file, FILES[file])
        
            FILES.del(file)
    except:
        echo "Failed to save " & file
        
proc savefiles() =
    for file in FILES.keys():
        savefile(file)

# ###
# Manipulating content

proc prepend(file: string, data: string, search="") =
    loadfile(file)
    if search == "":
        FILES[file] = data & FILES[file]
    else:
        let idx = FILES[file].find(search)
        if idx != -1:
            FILES[file] = FILES[file][0..<idx] & data & FILES[file][idx..<FILES[file].len()]

proc append(file: string, data: string, search="") =
    loadfile(file)
    if search == "":
        FILES[file] &= data
    else:
        let idx = FILES[file].find(search)
        let idy = idx + search.len()
        if idx != -1:
            FILES[file] = FILES[file][0..<idy] & data & FILES[file][idy..<FILES[file].len()]
    
proc freplace(file: string, pattern: string, repl="") =
    loadfile(file)
    if pattern in FILES[file]:
        FILES[file] = FILES[file].replace(pattern, repl)

proc freplace(file: string, pattern: Regex, repl="") =
    loadfile(file)
    if FILES[file].find(pattern).isSome():
        if "$#" in repl:
            for m in FILES[file].findIter(pattern):
                FILES[file] = FILES[file].replace(m.match, repl % m.captures[0])
        else:
            FILES[file] = FILES[file].replace(pattern, repl)

proc compile(dir="", file=""): string =
    proc fcompile(file: string): string =
        return "{.compile: \"$#\".}" % file.replace("\\", "/")
    
    var data = ""
    if dir != "" and dirExists(dir):
        for f in walkFiles(dir / "*.c"):
            data &= fcompile(f) & "\n"
    
    if file != "" and fileExists(file):
        data &= fcompile(file) & "\n"

    return data

proc fixfuncprotos(file: string) =
    var data = readFile(file)

    var edit = false
    for fp in data.findIter(re"(?m)(^.*?)[ ]*\(\*(.*?)\((.*?)\)\)[ \r\n]*\((.*?[\r\n]*.*?)\);"):
        var tdout = "typedef $# (*type_$#)($#);\n" % [fp.captures[0], fp.captures[1], fp.captures[3]] &
            "type_$# $#($#);" % [fp.captures[1], fp.captures[1], fp.captures[2]]
        data = data.replace(fp.match, tdout)
        edit = true

    if edit:
        writeFile(file, data)
        
# ###
# Convert to Nim

proc getincls(file: string): seq[string] =
    loadfile(file)
    result = @[]
    for f in FILES[file].findIter(re"(?m)^\s*#\s*include\s+(.*?)$"):
        var inc = f.captures[0].replace(re"""[<>"]""", "").strip()
        if FILTER in inc and (not exclude(inc)):
            result.add(inc)

    result = result.deduplicate()

proc getdefines(file: string): string =
    loadfile(file)
    result = ""
    for def in FILES[file].findIter(re"(?m)^(\s*#\s*define\s+[\w\d_]+\s+[\d.x]+)(?:\r|//|/*).*?$"):
        result &= def.captures[0] & "\n"

proc preprocess(file: string): string =
    var cmd = "gcc -E " & file
    for inc in INCLUDES:
        cmd &= " -I " & inc

    # Run preprocessor
    var data = execProc(cmd)

    # Include content only from file
    var rdata: Rope
    var start = false
    let sfile = file.replace("\\", "/")
    for line in data.splitLines():
        if line.strip() != "":
            if line[0] == '#':
                start = false
                if sfile in line.replace("\\", "/").replace("//", "/"):
                    start = true
            else:
                if start:
                    rdata.add(
                        line.replace("_Noreturn", "")
                            .replace("WINAPI", "")
                            .replace("__attribute__", "")
                            .replace(re"\(\([_a-z]+?\)\)", "")
                            .replace(re"\(\(__format__\(__printf__, \d, \d\)\)\);", ";") & "\n"
                    )
    return $rdata

proc ctags(file: string): string =
    var cmd = "ctags -o - --fields=+S+K --c-kinds=p --file-scope=no " & file
    var fps = execProc(cmd)

    var fdata = ""
    for line in fps.splitLines():
        var spl = line.split(re"\t")
        if spl.len() > 4:
            if spl[0] != "main":
                var fn = ""
                var match = spl[2].find(re"/\^(.*?)\(")
                if match.isSome():
                    fn = match.get().captures[0]
                    fn &= spl[4].replace("signature:", "") & ";"
                    fdata &= fn & "\n"

    return fdata
    
proc c2nim(fl, outfile, flags: string, recurse, preproc, ctag, define: bool, compile, dynlib: seq[string] = @[]) =
    var file = search(fl)
    if file == "":
        return
    
    if file in DONE:
        return

    echo "Processing " & file
    DONE.add(file)

    fixfuncprotos(file)

    var incout = ""
    if recurse:
        var incls = getincls(file)
        for inc in incls:
            incout &= "import " & inc.splitFile().name & "\n"
            c2nim(inc, getnimout(inc), flags, recurse, preproc, ctag, define)

    var cfile = file
    if preproc:
        cfile = "temp.c"
        writeFile(cfile, preprocess(file))
    elif ctag:
        cfile = "temp.c"
        writeFile(cfile, ctags(file))

    if define and (preproc or ctag):
        prepend(cfile, getdefines(file))
        savefile(cfile)

    var extflags = ""
    var passC = ""
    var outlib = ""
    if compile.len() != 0:
        passC = "import strutils\n"
        for inc in INCLUDES:
            passC &= ("""{.passC: "-I\"" & gorge("nimble path $#").strip() & "/$#\"".}""" % [OUTPUT, inc]) & "\n"
        passC &= "{.push importc.}\n{.push header: \"$#\".}\n" % fl
        #extflags = "--header:\"$#\"" % fl

    if dynlib.len() != 0:
        let win = "when defined(Windows):\n"
        let lin = "when defined(Linux):\n"
        let osx = "when defined(MacOSX):\n"
        var winlib, linlib, osxlib: string = ""
        for dl in dynlib:
            if dl.splitFile().ext == ".dll":
                winlib &= "  const dynlib$# = \"$#\"\n" % [OUTPUT, dl]
            if dl.splitFile().ext == ".so":
                linlib &= "  const dynlib$# = \"$#\"\n" % [OUTPUT, dl]
            if dl.splitFile().ext == ".dylib":
                osxlib &= "  const dynlib$# = \"$#\"\n" % [OUTPUT, dl]

        if winlib != "":
            outlib &= win & winlib & "\n"
        if linlib != "":
            outlib &= lin & linlib & "\n"
        if winlib != "":
            outlib &= osx & osxlib & "\n"
        
        if outlib != "":
            extflags &= " --dynlib:dynlib$#" % OUTPUT

    # Run c2nim on generated file
    var cmd = "c2nim $# $# --out:$# $#" % [flags, extflags, outfile, cfile]
    when defined(windows):
        cmd = "cmd /c " & cmd  
    discard execProc(cmd)

    if preproc:
        try:
            removeFile("temp.c")
        except:
            discard

    # Import nim modules
    if recurse:
        prepend(outfile, incout)

    # Nim doesn't like {.cdecl.} for type proc()
    freplace(outfile, re"(?m)(.*? = proc.*?){.cdecl.}", "$#")
    freplace(outfile, " {.cdecl.})", ")")

    # Include {.compile.} directives
    for cpl in compile:
        if getFileInfo(cpl).kind == pcFile:
            prepend(outfile, compile(file=cpl))
        else:
            prepend(outfile, compile(dir=cpl))

    # Add header file and include paths
    if passC != "":
        prepend(outfile, passC)
        append(outfile, "\n{.pop.}\n{.pop.}\n")

    # Add dynamic library         
    if outlib != "":
        prepend(outfile, outlib)

# ###
# Processor

proc runcfg(cfg: string) =
    if not fileExists(cfg):
        echo "Config doesn't exist: " & cfg
        quit()

    CONFIG = loadConfig(cfg)

    if CONFIG.hasKey("n.global"):
        if CONFIG["n.global"].hasKey("output"):
            OUTPUT = CONFIG["n.global"]["output"]
        if CONFIG["n.global"].hasKey("filter"):
            FILTER = CONFIG["n.global"]["filter"]

    if CONFIG.hasKey("n.include"):
        for inc in CONFIG["n.include"].keys():
            INCLUDES.add(inc)

    if CONFIG.hasKey("n.exclude"):
        for excl in CONFIG["n.exclude"].keys():
            EXCLUDES.add(excl)

    for file in CONFIG.keys():
        if file in @["n.global", "n.include", "n.exclude"]:
            continue

        var sfile = search(file)

        var srch = ""
        var action = ""
        var compile: seq[string] = @[]
        var dynlib: seq[string] = @[]
        for act in CONFIG[file].keys():
            action = act.replace(re"\..*", "")
            if action == "create":
                writeFile(file, CONFIG[file][act])
            elif action in @["prepend", "append", "replace", "compile", "dynlib"] and sfile != "":
                if action == "prepend":
                    if srch != "":
                        prepend(sfile, CONFIG[file][act], CONFIG[file][srch])
                    else:
                        prepend(sfile, CONFIG[file][act])
                elif action == "append":
                    if srch != "":
                        append(sfile, CONFIG[file][act], CONFIG[file][srch])
                    else:
                        append(sfile, CONFIG[file][act])
                elif action == "replace":
                    if srch != "":
                        freplace(sfile, CONFIG[file][srch], CONFIG[file][act])
                elif action == "compile":
                    compile.add(CONFIG[file][act])
                elif action == "dynlib":
                    dynlib.add(CONFIG[file][act])
                srch = ""
            elif action == "search":
                srch = act
        
        if file.splitFile().ext != ".nim":
            var recurse = false
            var preproc = false
            var ctag = false
            var define = false
            var flags = "--stdcall"

            # Save C files in case they have changed
            savefile(sfile)

            for act in CONFIG[file].keys():
                if CONFIG[file][act] == "true":
                    if act == "recurse":
                        recurse = true
                    elif act == "preprocess":
                        preproc = true
                    elif act == "ctags":
                        ctag = true
                    elif act == "defines":
                        define = true
                elif act == "flags":
                    flags = CONFIG[file][act]


            c2nim(file, getnimout(file), flags, recurse, preproc, ctag, define, compile, dynlib)
        
# ###
# Main loop

if paramCount() == 0:
    echo "nimgen file.cfg"
    quit()

for i in 1..paramCount():
    runcfg(paramStr(i))

savefiles()