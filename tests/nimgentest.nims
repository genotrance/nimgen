import ospaths
import strutils

for comp in @["nimbass", "nimfuzz", "nimssl"]:
    cd(".."/comp)
    exec "nimble install -y"
    exec "nimble test"
    cd(".."/"nimgen")
