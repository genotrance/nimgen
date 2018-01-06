import ospaths
import strutils

for comp in @["nimbass", "nimfuzz", "nimssl", "nimssh2"]:
    withDir(".."/comp):
        exec "nimble install -y"
        exec "nimble test"
