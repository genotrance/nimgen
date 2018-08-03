import nimgen/fileops, common, regex, os

import unittest

let testFileContent = """
this is text
this is text
replace me
prepend me
end
"""

let prependMiddleExpected = """
this is text
this is text
replace me
prepended data
prepend me
end
"""

let prependEndExpected = """
this is text
this is text
replace me
prepend me
data
end
"""

let appendEndExpected = """
this is text
this is text
replace me
prepend me
end
data
"""

let appendMiddleExpected = """
this is data
 text
this is text
replace me
prepend me
end
"""

let freplaceDefaultExpected = """


replace me
prepend me
end
"""

let freplaceWithExpected = """
this is text
this is text
foobar
prepend me
end
"""

let freplaceRegexExpected = """
foobar
foobar
replace me
prepend me
end
"""

let commentExpected = """
this is text
this is text
//replace me
//prepend me
//end
"""

let commentMiddleExpected = """
this //is text
//this is text
replace me
prepend me
end
"""


let dataDir = currentSourcePath().splitPath().head / "data"

let testfilename = dataDir / "testing.txt"


suite "test file ops":
  if not dataDir.dirExists():
    dataDir.createDir()

  setup:
    if testfilename.existsFile():
      removeFile(testfilename)
    writeFile(testfilename, testFileContent)

  ################### Prepend #######################

  test "prepend at beginning of file":
    prepend(testfilename, "data\n")
    let expected = "data\n" & testFileContent
    testfilename.checkFile(expected)

  test "prepend at middle of file":
    prepend(testfilename, "prepended data\n", "prepend me")
    testfilename.checkFile(prependMiddleExpected)

  test "prepend at end of file":
    prepend(testfilename, "data\n", "end\n")
    testfilename.checkFile(prependEndExpected)

  ################### Pipe #########################

  test "pipe command into file":
    when defined(windows):
      pipe(testfilename, "ECHO foo > $file")
      testfilename.checkFile("foo")
    else:
      pipe(testfilename, "cat $file | grep 'this is text'")
      testfilename.checkFile("this is text\nthis is text")

  ################# Append #########################

  test "append file end":
    append(testfilename, "data\n")
    testfilename.checkFile(appendEndExpected)

  test "append file middle":
    append(testfilename, " data\n", "this is")
    testfilename.checkFile(appendMiddleExpected)

  ################# FReplace #########################

  test "freplace default empty":
    freplace(testfilename, "this is text")
    testfilename.checkFile(freplaceDefaultExpected)

  test "freplace with content":
    freplace(testfilename, "replace me", "foobar")
    testfilename.checkFile(freplaceWithExpected)

  test "freplace regex":
    freplace(testfilename, re"this .*", "foobar")
    testfilename.checkFile(freplaceRegexExpected)

  ####################### Comment ######################

  test "comment":
    comment(testfilename, "replace me", "3")
    testfilename.checkFile(commentExpected)

  test "comment over length":
    comment(testfilename, "replace me", "10")
    testfilename.checkFile(commentExpected)

  test "comment negative":
    comment(testfilename, "replace me", "-3")
    testfilename.checkFile(testFileContent)

  test "comment zero":
    comment(testfilename, "replace me", "0")
    testfilename.checkFile(testFileContent)

  test "comment middle":
    comment(testfilename, "is text", "2")
    testfilename.checkFile(commentMiddleExpected)

  ############### Static inline removal ################

  test "replace static inline with front braces at end of line":

    let
      file = dataDir / "teststaticfrontbraces.h"
      resFile = dataDir / "teststaticexpectedfrontbraces.h"

      test = readFile(file)
      expected = readFile(resFile)

    writeFile(testfilename, test)

    removeStatic(testfilename)
    testfilename.checkFile(expected)

    reAddStatic(testfilename)
    testfilename.checkFile(test)

  test "replace static inline with newline before brace":

    let
      file = dataDir / "teststaticnewlinebraces.h"
      resFile = dataDir / "teststaticexpectednewlinebraces.h"
      reAddedFile = dataDir / "teststaticnewlinebracesreadded.h"

      test = readFile(file)
      expected = readFile(resFile)
      reAdded = readFile(reAddedFile)

    writeFile(testfilename, test)

    removeStatic(testfilename)
    testfilename.checkFile(expected)

    reAddStatic(testfilename)
    testfilename.checkFile(reAdded)
