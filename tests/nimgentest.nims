import distros, ospaths, strutils

var
  full = true
  comps = @["libsvm", "nim7z", "nimarchive", "nimbass", "nimbigwig", "nimclipboard",
            "nimfuzz", "nimpcre", "nimrax", "nimssl", "nimssh2"]

if detectOs(Windows):
  comps.add("nimkerberos")

if paramCount() > 2:
  for i in 3 .. paramCount():
    if paramStr(i) == "--full":
      full = true
    elif paramStr(i).len() > 10 and "--comps=" in paramStr(i)[0 ..< 8]:
      comps = paramStr(i)[8 .. ^1].split(",")

for comp in comps:
  if not dirExists(".."/comp):
    withDir(".."):
      exec "git clone --depth=1 https://github.com/genotrance/" & comp

  exec "nimble uninstall -y " & comp, "", ""
  withDir(".."/comp):
    exec "git pull"

    if full:
      rmDir(comp)

      exec "nimble install -y"
      exec "nimble test"

    exec "nimble install -y"
    exec "nimble test"

  if dirExists("web"/comp):
    rmDir("web"/comp)

  mkDir("web"/comp)
  for file in listFiles(".."/comp/comp) & listFiles(".."/comp):
    if file.splitFile().ext == ".nim":
      cpFile(file, "web"/comp/extractFilename(file))

  cpFile("web"/"nimdoc.cfg", "web"/comp/"nimdoc.cfg")
  withDir("web"/comp):
    for file in listFiles("."):
      if file.splitFile().ext == ".nim":
        exec "nim doc --git.url:. --index:on -o:" & file.changeFileExt("html") & " " & file
        exec "pygmentize -f html -O full,linenos=1,anchorlinenos=True,lineanchors=L,style=vs -o " & file & ".html " & file

    exec "nim buildIndex -o:index.html ."
  rmFile("web"/comp/"nimdoc.cfg")
