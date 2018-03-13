import distros
import ospaths
import strutils

var comps = @["libsvm", "nimbass", "nimbigwig", "nimfuzz", "nimrax", "nimssl", "nimssh2"]
if detectOs(Windows):
    comps.add("nimkerberos")

for comp in comps:
    if dirExists(".."/comp):
        exec "nimble uninstall -y " & comp, "", ""
        withDir(".."/comp):
            rmDir(comp)
            exec "nimble install -y"
            exec "nimble test"

            exec "nimble install -y"
            exec "nimble test"
