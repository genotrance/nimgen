import unittest

proc checkFile*(filepath, expected: string) =
  let result = readFile(filepath)
  check result == expected
