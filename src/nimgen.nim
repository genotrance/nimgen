import os

import nimgen/config

for i in commandLineParams():
  if i != "-f":
    runCfg(i)
