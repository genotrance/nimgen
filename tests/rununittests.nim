import os, osproc, strutils

proc main() =
  for file in walkFiles(currentSourcePath().splitPath().head / "unittests/*.nim"):
    let (path, fname, ext) = file.splitFile()
    if fname.startswith("test"):
      discard execCmd "nim c -r " & file
main()
