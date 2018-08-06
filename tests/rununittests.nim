import os, osproc, strutils

proc main() =
  var failures = 0
  for file in walkFiles(currentSourcePath().splitPath().head / "unittests/*.nim"):
    let (path, fname, ext) = file.splitFile()
    if fname.startswith("test"):
      failures += execCmd "nim c -r " & file
  quit(failures)
main()
