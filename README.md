Nimgen is a helper for [c2nim](https://github.com/nim-lang/c2nim/) to simpilfy and automate the wrapping of C libraries.

Nimgen can be used to automate the process of manipulating C files so that c2nim can be run on them without issues. This includes adding/removing code snippets, removal of complex preprocessor definitions that c2nim doesn't yet comprehend and recursively running on #include files.

__Installation__

Nimgen can be installed via [Nimble](https://github.com/nim-lang/nimble):

```> nimble install https://github.com/genotrance/nimgen```

This will download, build and install nimgen in the standard Nimble package location, typically ~/.nimble. Once installed, it can be run just like c2nim.

__Usage__

Nimgen is driven by a simple .cfg file that is read using the Nim [parsecfg](https://nim-lang.org/docs/parsecfg.html) module. The sections of the file are described further below. 

```> nimgen package.cfg```

A Nimble package for a library that is wrapped with nimgen will have the following:-

* The .cfg file that tells nimgen what exactly to do
* Nimgen defined as a dependency defined in the .nimble file
* Steps within the .nimble file to download the source code that is being wrapped

This way, the library source code doesn't need to get checked into the Nimble package and can evolve independently.

Nimble already requires Git so those commands can be assumed to be present to download source from a repository. Mercurial is also suggested but depends on the user. Downloading arbitrary files depends on the OS. For Linux, wget/curl can be assumed. On Windows, [powershell](https://superuser.com/questions/362152/native-alternative-to-wget-in-windows-powershell) can be used.

__Capabilities & Limitations__

Nimgen supports compiling in C/C++ sources as well as loading in dynamic libraries at this time. Support for static libraries (.a, .lib) are still to come.

To see examples of nimgen in action, the [nimssl](https://github.com/genotrance/nimssl) library is a good example of C code getting compiled in whereas [nimbass](https://github.com/genotrance/nimbass) is an example of linking with a dynamic library.

Nimgen only supports the ```gcc``` preprocessor at this time. Support for detecting and using other preprocessors is TBD.

__Config file__

_[n.global]_

```output``` = name of the Nimble project once installed, also location to place generated .nim files

```quotes``` = pick up any headers included using "" (and not <> which is typically used for standard headers) [default: true]

```filter``` = string to identify and recurse into library .h files in #include statements and exclude standard headers

_[n.include]_

List of all directories, one per line, to include in the search path. This is used by:-
* The preprocessor for #include files
* Nimgen to find #include files that are recursively processed

Nimgen also adds {.passC.} declarations into the generated .nim files for these include paths if compiling source files directly.

_[n.exclude]_

List of all directories or files to exclude from all parsing. If an entry here matches any portion of a file, it is excluded from recursive processing.

_[n.prepare]_

The following keys can be used to prepare dependencies such as downloading ZIP files, cloning Git repositories, etc. Multiple entries are possible by appending any .string to the key. E.g. download.file1. -win, -lin and -osx can be used for OS specific tasks. E.g. download-win

```download``` = url to download to the output directory. ZIP files are automatically extracted. Files are not redownloaded if already present but re-extracted

```git``` = url of Git repository to clone. Full repo is pulled so gitremote + gitsparse is preferable. Resets to HEAD if already present

```gitremote``` = url of Git repository to partially checkout. Use with gitsparse to pull only files and dirs of interest

```gitsparse``` = list of files and/or dirs to include in partial checkout, one per line. Resets to HEAD if already present

```execute``` = command to run during preparation

_[n.wildcard]_

File wildcards such as *.nim, ssl*.h, etc. can be used to perform tasks across a group of files. This is useful to define common operations such as global text replacements without having to specify an explicit section for every single file. These operations will be performed on every matching file that is defined as a _sourcefile_ or recursed files. Only applies on source files following the wildcard declarations.

```wildcard``` = pattern to match against. All keys following the wildcard declaration will apply to matched files

_[sourcefile]_

The following keys apply to library source code and help with generating the .nim files. -win, -lin and -osx can be used for OS specific tasks. E.g. dynlib-win

```recurse``` = find #include files and process them [default: false]

```preprocess``` = run preprocessor (gcc -E) on file to remove #defines, etc. [default: false] - this is especially useful when c2nim doesn't support complex preprocessor usage

```ctags``` = run ctags on file to filter out function definitions [default: false] - this requires the ctags executable and is an alternative to filter out preprocessor complexity

```defines``` = pulls out simple #defines of ints, floats and hex values for separate conversion [default: false] - works only when preprocess or ctags is used and helps include useful definitions in generated .nim file

```flags``` = flags to pass to the c2nim process in "quotes" [default: --stdcall]. --cdecl, --assumedef, --assumendef may be useful

```ppflags``` = flags to pass to the preprocessor [default: ""]. -D for gcc and others may be useful

```noprocess``` = do not process this source file with c2nim [default: false] - this is useful if a file only needs to be manipulated

Multiple entries for the all following keys are possible by appending any .string to the key. E.g. dynlib.win, compile.dir

```compile``` = file or dir of files of source code to {.compile.} into generated .nim

```dynlib``` = dynamic library to load at runtime for generated .nim procs

The following keys apply to library source code (before processing) and generated .nim files (after processing) and allow manipulating the files as required to enable successful wrapping. They are not propagated to #include files when ```recurse = true```.

```create``` = create a file at exact location with contents specified. File needs to be in the _[n.exclude]_ list in order to be created.

```search``` = search string providing context for following prepend/append/replace directives

```prepend``` = string value to prepend into file at beginning or before search

```append``` = string value to append into file at the end or after search

```replace``` = string value to replace search string in file

__Feedback__

Nimgen is a work in progress and any feedback or suggestions are welcome. It is hosted on [GitHub](https://github.com/genotrance/nimgen) with an MIT license so issues, forks and PRs are most appreciated.
