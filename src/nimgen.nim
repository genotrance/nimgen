import os

import nimgen/runcfg

for i in commandLineParams():
  if i != "-f":
    runCfg(i)
