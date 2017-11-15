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

var DONE: seq[string] = @[]

var CONFIG: Config
var FILTER = ""
var QUOTES = true
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
    var nimout = file.splitFile().name.replace(re"[\-\.]", "_") & ".nim"
    if OUTPUT != "":
        nimout = OUTPUT/nimout

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

template withFile(file: string, body: untyped): untyped =
    if fileExists(file):
        var f: File
        while true:
            try:
                f = open(file)
                break
            except:
                sleep(100)

        var contentOrig = f.readAll()
        f.close()
        var content {.inject.} = contentOrig

        body

        if content != contentOrig:
            var f = open(file, fmWrite)
            write(f, content)
            f.close()
    else:
        echo "Missing file " & file

# ###
# Manipulating content

proc prepend(file: string, data: string, search="") =
    withFile(file):
        if search == "":
            content = data & content
        else:
            let idx = content.find(search)
            if idx != -1:
                content = content[0..<idx] & data & content[idx..<content.len()]

proc append(file: string, data: string, search="") =
    withFile(file):
        if search == "":
            content &= data
        else:
            let idx = content.find(search)
            let idy = idx + search.len()
            if idx != -1:
                content = content[0..<idy] & data & content[idy..<content.len()]
    
proc freplace(file: string, pattern: string, repl="") =
    withFile(file):
        if pattern in content:
            content = content.replace(pattern, repl)

proc freplace(file: string, pattern: Regex, repl="") =
    withFile(file):
        if content.find(pattern).isSome():
            if "$#" in repl:
                for m in content.findIter(pattern):
                    content = content.replace(m.match, repl % m.captures[0])
            else:
                content = content.replace(pattern, repl)

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
    withFile(file):
        for fp in content.findIter(re"(?m)(^.*?)[ ]*\(\*(.*?)\((.*?)\)\)[ \r\n]*\((.*?[\r\n]*.*?)\);"):
            var tdout = "typedef $# (*type_$#)($#);\n" % [fp.captures[0], fp.captures[1], fp.captures[3]] &
                "type_$# $#($#);" % [fp.captures[1], fp.captures[1], fp.captures[2]]
            content = content.replace(fp.match, tdout)
        
# ###
# Convert to Nim

proc getincls(file: string): seq[string] =
    result = @[]
    withFile(file):
        for f in content.findIter(re"(?m)^\s*#\s*include\s+(.*?)$"):
            var inc = f.captures[0].strip()
            if ((QUOTES and inc.contains("\"")) or (FILTER != "" and FILTER in inc)) and (not exclude(inc)):
                result.add(inc.replace(re"""[<>"]""", "").strip())

        result = result.deduplicate()

proc getdefines(file: string): string =
    withFile(file):
        result = ""
        for def in content.findIter(re"(?m)^(\s*#\s*define\s+[\w\d_]+\s+[\d.x]+)(?:\r|//|/*).*?$"):
            result &= def.captures[0] & "\n"

proc preprocess(file, ppflags, flags: string): string =
    var pproc = "gcc"
    if flags.contains("cpp"):
        pproc = "g++"
    var cmd = "$# -E $# $#" % [pproc, ppflags, file]
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
            if line[0] == '#' and not line.contains("#pragma"):
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
    
proc c2nim(fl, outfile, flags, ppflags: string, recurse, preproc, ctag, define: bool, dynlib, compile: seq[string] = @[]) =
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
            incout &= "import " & inc.splitFile().name.replace(re"[\-\.]", "_") & "\n"
            c2nim(inc, getnimout(inc), flags, ppflags, recurse, preproc, ctag, define, dynlib)

    var cfile = file
    if preproc:
        cfile = "temp-$#.c" % [outfile.extractFilename()]
        writeFile(cfile, preprocess(file, ppflags, flags))
    elif ctag:
        cfile = "temp-$#.c" % [outfile.extractFilename()]
        writeFile(cfile, ctags(file))

    if define and (preproc or ctag):
        prepend(cfile, getdefines(file))

    var extflags = ""
    var passC = ""
    var outlib = ""

    passC = "import strutils\n"
    for inc in INCLUDES:
        passC &= ("""{.passC: "-I\"" & gorge("nimble path $#").strip() & "/$#\"".}""" % [OUTPUT, inc]) & "\n"

    let fname = file.splitFile().name
    if dynlib.len() != 0:
        let win = "when defined(Windows):\n"
        let lin = "when defined(Linux):\n"
        let osx = "when defined(MacOSX):\n"
        var winlib, linlib, osxlib: string = ""
        for dl in dynlib:
            let lib = "  const dynlib$# = \"$#\"\n" % [fname, dl]
            if dl.splitFile().ext == ".dll":
                winlib &= lib
            if dl.splitFile().ext == ".so":
                linlib &= lib
            if dl.splitFile().ext == ".dylib":
                osxlib &= lib

        if winlib != "":
            outlib &= win & winlib & "\n"
        if linlib != "":
            outlib &= lin & linlib & "\n"
        if winlib != "":
            outlib &= osx & osxlib & "\n"
        
        if outlib != "":
            extflags &= " --dynlib:dynlib$#" % fname
    else:
        passC &= "const header$# = \"$#\"\n" % [fname, fl]
        extflags = "--header:header$#" % fname

    # Run c2nim on generated file
    var cmd = "c2nim $# $# --out:$# $#" % [flags, extflags, outfile, cfile]
    when defined(windows):
        cmd = "cmd /c " & cmd  
    discard execProc(cmd)

    if preproc or ctag:
        try:
            removeFile(cfile)
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
        if CONFIG["n.global"].hasKey("quotes"):
            if CONFIG["n.global"]["quotes"] == "false":
                QUOTES = false
    
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
                createDir(file.splitPath().head)
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
            var noprocess = false
            var flags = "--stdcall"
            var ppflags = ""

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
                    elif act == "noprocess":
                        noprocess = true
                elif act == "flags":
                    flags = CONFIG[file][act]
                elif act == "ppflags":
                    ppflags = CONFIG[file][act]

            if not noprocess:
                c2nim(file, getnimout(file), flags, ppflags, recurse, preproc, ctag, define, dynlib, compile)
        
# ###
# Main loop

if paramCount() == 0:
    echo "nimgen file.cfg"
    quit()

for i in 1..paramCount():
    runcfg(paramStr(i))
