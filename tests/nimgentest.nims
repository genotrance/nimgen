import ospaths
import strutils

for comp in @["nimbass", "nimfuzz", "nimssl"]:
    withDir(".."/comp):
        exec "nimble install -y"
        exec "nimble test"
