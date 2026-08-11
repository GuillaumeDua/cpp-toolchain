# Check scripts

Scripts that ask a question about a compiler, or about a built image, and report the answer.

The two under [`details/`](details/) are also the image validation gate:

- the `validate-build` and `validate-runtime` stages run them, and a non-zero exit fails the build.  
- What each one proves, which stage runs it and how to reproduce a failure is [docs/IMAGES_VALIDATION.md](../../docs/IMAGES_VALIDATION.md).

## Standalone

| Script                                | Purpose                                                              |
| ------------------------------------- | -------------------------------------------------------------------- |
| `compiler-supported-cxx-standards.sh` | Which C++ standards a compiler accepts, ordered by `__cplusplus`     |
| `cxx-stdlibs.sh`                      | Which C++ standard libraries are installed, and what ABI they expose |

These depend on nothing in this repository - point them at any compiler on any machine.  
Fetch either on its own when you want the answer without an image or a checkout:

```bash
base=https://raw.githubusercontent.com/GuillaumeDua/cpp-toolchain/main/scripts/checks
wget "${base}/compiler-supported-cxx-standards.sh"
wget "${base}/cxx-stdlibs.sh"
```

### `compiler-supported-cxx-standards.sh`

From a checkout it is the same script:

```bash
scripts/checks/compiler-supported-cxx-standards.sh --stable g++-16
c++03 -> __cplusplus=199711
...
c++26 -> __cplusplus=202400
```

`--stable` drops draft spellings such as `c++2c`, `--greatest` keeps only the highest standard,
and `--format` narrows each line to one field - `std` for `c++26`, `cplusplus` for `202400`.
`--format=std` is spelled the way the compiler spells it, so it feeds straight back in:

```bash
g++-16 -std="$(scripts/checks/compiler-supported-cxx-standards.sh --greatest --stable --format=std g++-16)" main.cpp
```

`--help` is the full reference.

### `cxx-stdlibs.sh`

Which standard libraries are installed, and the two things that actually break a build:

- the `SONAME` a binary will load,
- the `ABI` version it needs to find there.

```bash
> bash scripts/checks/cxx-stdlibs.sh

libc++ 20.1.7 -> soname=libc++.so.1.0.20 abi=- cxxabi=libc++abi.so.1.0.20 package=libc++1-20
libc++ 22.1.8 -> soname=libc++.so.1 abi=LIBCPP_ABI_1 cxxabi=libc++abi.so.1 package=libc++1
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libstdc++6
```

> [!IMPORTANT]
> `abi=-` for `libc++ 20.1.7` above is not a missing answer.  
> That runtime is installed without its headers,
> which is where the number would have to be read from.

> [!TIP]
>
> `abi` is the version a binary demands of the library at load time.
> It is the field behind this:
>
> ```text
> ./a.out: /lib/x86_64-linux-gnu/libstdc++.so.6: version `GLIBCXX_3.4.32' not found
> ```
>
> That binary needs `3.4.32`.
> Ask the host how high its libstdc++ goes:
>
> ```bash
> bash scripts/checks/cxx-stdlibs.sh --stdlib=libstdc++ --format=abi
> GLIBCXX_3.4.35
> ```
>
> `3.4.35` is above the `3.4.32` asked for, so this host can run it.  
> The error came from a host whose `libstdc++` stopped lower,
> and the fix there is a newer libstdc++, not a rebuild.

> [!WARNING]
> That "not a rebuild" holds for a *symbol version* miss, the failure shown above,
> and not for libstdc++'s other common break.  
> The CXX11 string ABI split fails at **link** time naming `std::__cxx11::` symbols,
> not at load time, and no `abi` value above can see it:
> it is a compile-time choice, not a property of the installed library.
> That one *does* need a rebuild, or a matching `-D_GLIBCXX_USE_CXX11_ABI`.  
> `--compilers` is where it shows up, as `abi=cxx11` or `abi=cxx03`.

The two implementations answer in different currencies,
because only one of them has GNU symbol versions:

| Implementation | `abi` | `cxxabi` |
| -------------- | ----- | -------- |
| `libstdc++` | greatest `GLIBCXX_` in the ELF<br>ex: `GLIBCXX_3.4.35` | greatest `CXXABI_` in that same ELF<br>ex: `CXXABI_1.3.17` - its C++ ABI lives inside `libstdc++.so` |
| `libc++` | `_LIBCPP_ABI_VERSION` from the headers<br>ex: `LIBCPP_ABI_1` | the `SONAME` of the C++ ABI library it keeps apart<br>ex: `libc++abi.so.1` |

libc++'s ABI is not *absent* from its binary, only unversioned there:
the `std::__1` namespace is in every mangled name,
but never separably from the symbol that follows it.
That is why the headers are the only clean read,
and why `abi=-` is the honest answer without them.

`--compilers` adds what each compiler actually compiles against,
which is not always the newest one installed -
a compiler picks headers off its own search path.
It takes the same shape as `--versions` and `--targets` do in [`install/`](../install/):
`all`, or a space-separated list.

```bash
> bash scripts/checks/cxx-stdlibs.sh --compilers='clang++-18'

compilers:
clang++-18 -> libc++ 22.1.8 abi=LIBCPP_ABI_1 headers=/usr/lib/llvm-22/include/c++/v1
clang++-18 -> libstdc++ 16 abi=cxx11 headers=/usr/include/c++/16
```

`Clang 18` compiling against `libc++ 22` is not a misreading:
`/usr/include/c++/v1` is a symlink into the newest LLVM's tree,
so every clang installed shares one libc++.

Bare `--compilers` is `--compilers=all`, every `g++`/`clang++` on `PATH`.
Naming the ones you care about instead is worth it -
asking every compiler a host has costs about a minute:

```bash
> bash scripts/checks/cxx-stdlibs.sh --compilers='g++-13 clang++-22' --format=version

20.1.7
22.1.8
16
13
```

The value needs its `=`, as an optional value always does -
written apart it could not be told from the next option.
There are no positional arguments.

`--format=fields` is the parseable form, one `key=value` set per line,
tagged with the view it came from, so both can be read off one stream.
The library view needs neither a compiler nor binutils,
so it still answers inside a runtime-only image:

```bash
> bash scripts/checks/cxx-stdlibs.sh --format=fields

view=library impl=libstdc++ version=16 soname=libstdc++.so.6 path=/usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.35 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libstdc++6
```

A field this host cannot answer reads `-` rather than being dropped,
so every line of a view keeps its shape.  
`--help` is the full reference.

## [details/](details/)

| Script                                               | Purpose                                                                                                  |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `package-origins.sh <build\|runtime>`                | Every toolchain package comes from the repository that owns it, not from the Ubuntu archive              |
| `cxx-runtime.sh <compile\|inspect\|run> <directory>` | Compiles the payload for every standard, proves it links against a C++ runtime dynamically, then runs it |

Implementation details of this gate, in the C++ sense of a nested `detail` namespace:
they know this repo's expected package origins,
and they ask [`scripts/install/`](../install/) which compilers are installed rather than guessing.
That reach is why the validate stages copy `scripts/` whole -
a layout that separates the two fails loudly rather than silently finding no compilers.

Both report **every** failure before exiting, so one run tells you everything that is wrong.
Both also run against a plain checkout, which is the quickest way to iterate on them;
they discover whatever the host has, so expect a wider matrix than an image produces.
