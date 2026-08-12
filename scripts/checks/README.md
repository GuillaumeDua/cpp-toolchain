# Check scripts

Scripts that ask a question about a compiler, or about a built image, and report the answer.

The two under [`details/`](details/) are also the image validation gate:

- the `validate-build` and `validate-runtime` stages run them, and a non-zero exit fails the build.  
- What each one proves, which stage runs it and how to reproduce a failure is [docs/IMAGES_VALIDATION.md](../../docs/IMAGES_VALIDATION.md).

## Standalone

| Script             | Purpose                                                              |
| ------------------ | -------------------------------------------------------------------- |
| `cxx-standards.sh` | Which C++ standards a compiler accepts, ordered by `__cplusplus`     |
| `cxx-stdlibs.sh`   | Which C++ standard libraries are installed, and what ABI they expose |

These depend on nothing in this repository - point them at any compiler on any machine.  
Fetch either on its own when you want the answer without an image or a checkout:

```bash
base=https://raw.githubusercontent.com/GuillaumeDua/cpp-toolchain/main/scripts/checks
wget "${base}/cxx-standards.sh"
wget "${base}/cxx-stdlibs.sh"
```

### `cxx-standards.sh`

From a checkout it is the same script:

```bash
scripts/checks/cxx-standards.sh --stable g++-16
c++03 -> __cplusplus=199711
...
c++26 -> __cplusplus=202400
```

`--stable` drops draft spellings such as `c++2c`, `--greatest` keeps only the highest standard,
and `--format` narrows each line to one field - `std` for `c++26`, `cplusplus` for `202400`.
`--format=std` is spelled the way the compiler spells it, so it feeds straight back in:

```bash
g++-16 -std="$(scripts/checks/cxx-standards.sh --greatest --stable --format=std g++-16)" main.cpp
```

`--help` is the full reference.

### `cxx-stdlibs.sh`

Which standard libraries are installed, and the two things that actually break a build:

- the `SONAME` a binary will load,
- the `ABI` version it needs to find there.

```bash
> bash scripts/checks/cxx-stdlibs.sh

libc++ 20.1.7 -> soname=libc++.so.1.0.20 abi=LIBCPP_ABI_1 cxxabi=libc++abi.so.1.0.20 package=libc++1-20
libc++ 22.1.8 -> soname=libc++.so.1 abi=LIBCPP_ABI_1 cxxabi=libc++abi.so.1 package=libc++1
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libstdc++6
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=lib32stdc++6
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libx32stdc++6
```

One row is one installed runtime, not one implementation.  
`libstdc++` appears three times because [`gcc.sh`](../install/gcc.sh) installs multilib by default,
which adds a 32-bit and an x32 build beside the 64-bit one:
same release and same ABI, a different secondary ABI,
and `package` is the field that tells them apart.
These images carry them, so expect these rows.

> [!IMPORTANT]
> Every field above comes out of the binaries themselves, not out of a `-dev` package.  
> `libc++ 20.1.7` here is a runtime installed *without* its headers and still reports its ABI,
> because both implementations state that inside the library being described.
> The whole library view therefore works on a runtime-only image:
> no compiler, no binutils, no headers, nothing but the shared objects.

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
> The compiler view is where it shows up, as `abi=cxx11` or `abi=cxx03`.

The two implementations answer in different currencies,
because only one of them has GNU symbol versions:

| Implementation | `abi` | `cxxabi` |
| -------------- | ----- | -------- |
| `libstdc++` | greatest `GLIBCXX_` in the ELF<br>ex: `GLIBCXX_3.4.35` | greatest `CXXABI_` in that same ELF<br>ex: `CXXABI_1.3.17` - its C++ ABI lives inside `libstdc++.so` |
| `libc++` | the `std::__N` inline namespace in the ELF<br>ex: `LIBCPP_ABI_1` | the `SONAME` of the C++ ABI library it keeps apart<br>ex: `libc++abi.so.1` |

*Unversioned* is not the same as *unstated*.
libc++ has no GNU symbol versions, but it puts its ABI in an inline namespace, `std::__1`,
that every mangled name in the library repeats - so the binary does say which ABI it is.
Mangling is length-prefixed, which is what makes it readable:
`St3__1` is the substitution for `std::` followed by a *three-character* identifier,
so the digits after it belong to the next component's length and not to the namespace.

`_LIBCPP_ABI_VERSION` in the headers says the same thing and is kept as the fallback,
for a build whose namespace was renamed - the Android NDK's `__ndk1`, say -
or an ABI numbered past a single digit.

#### The two views

Everything above is the **library** view: what is installed.
The **compiler** view answers a different question -
what each compiler actually compiles against,
which is not always the newest one installed, because a compiler picks headers
off its own search path. `--compilers` selects it, and says which compilers to ask.
It takes the same shape as `--versions` and `--targets` do in [`install/`](../install/):
`all`, or a space-separated list.

```bash
> bash scripts/checks/cxx-stdlibs.sh --compilers='clang++-18'

clang++-18 -> libc++ 22.1.8 abi=LIBCPP_ABI_1 headers=/usr/lib/llvm-22/include/c++/v1
clang++-18 -> libstdc++ 16 abi=cxx11 headers=/usr/include/c++/16
```

`Clang 18` compiling against `libc++ 22` is not a misreading:
`/usr/include/c++/v1` is a symlink into the newest LLVM's tree,
so every clang installed shares one libc++.

> [!IMPORTANT]
> One view answers at a time. `--compilers` **selects** the compiler view rather than
> appending to the library one, so the command above prints no library rows at all.
> `--view=all` is how both are asked for at once, and it is worth asking when the
> question is the *gap* between them:

```bash
> bash scripts/checks/cxx-stdlibs.sh --view=all --compilers='clang++-18'

libc++ 20.1.7 -> soname=libc++.so.1.0.20 abi=LIBCPP_ABI_1 cxxabi=libc++abi.so.1.0.20 package=libc++1-20
libc++ 22.1.8 -> soname=libc++.so.1 abi=LIBCPP_ABI_1 cxxabi=libc++abi.so.1 package=libc++1
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libstdc++6
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=lib32stdc++6
libstdc++ 16 -> soname=libstdc++.so.6 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libx32stdc++6

compilers:
clang++-18 -> libc++ 22.1.8 abi=LIBCPP_ABI_1 headers=/usr/lib/llvm-22/include/c++/v1
clang++-18 -> libstdc++ 16 abi=cxx11 headers=/usr/include/c++/16
```

`libc++ 20.1.7` is installed and no compiler here reaches it.
That is the whole reason the two views exist separately.

Bare `--compilers` is `--compilers=all`, every `g++`/`clang++` on `PATH`.
Naming the ones you care about instead is worth it -
asking every compiler a host has costs about a minute.
`--view=compiler` is the same thing spelled out, for when no filter is wanted.

`--format=fields` is the parseable form, one `key=value` set per line,
tagged with the view it came from, so `--view=all` can be read off one stream.
The library view needs neither a compiler nor binutils,
so it still answers inside a runtime-only image:

```bash
> bash scripts/checks/cxx-stdlibs.sh --format=fields

view=library impl=libstdc++ version=16 soname=libstdc++.so.6 path=/usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.35 abi=GLIBCXX_3.4.35 cxxabi=CXXABI_1.3.17 package=libstdc++6
```

A field this host cannot answer reads `-` rather than being dropped,
so every line of a view keeps its shape.

The whole surface, of which the examples above use a part:

| Option        | Values                                                  | Default                    |
| ------------- | ------------------------------------------------------- | -------------------------- |
| `--view`      | `library`, `compiler`, `all`                            | `library`; `compiler` if `--compilers` |
| `--stdlib`    | `all`, `libstdc++`, `libc++`                            | `all`                      |
| `--compilers` | `all`, or a space-separated list of compilers           | `all` if bare              |
| `--format`    | `default`, `name`, `version`, `soname`, `abi`, `fields` | `default`                  |

The four narrowing formats print one field per line, deduplicated:
`name` gives `libstdc++`, `version` gives `16`, `soname` gives `libstdc++.so.6`,
`abi` gives `GLIBCXX_3.4.35`.
They are what makes the script scriptable - the sample above collapses to a single answer:

```bash
> bash scripts/checks/cxx-stdlibs.sh --stdlib=libstdc++ --format=soname

libstdc++.so.6
```

They print nothing that says which view a line came from, so they answer for one view
and `--view=all` is **refused** rather than answered - an installed runtime's
`GLIBCXX_3.4.35` and a compiler's `cxx11` are two different facts,
and one flat list holding both cannot say which is which.
Narrow to a view, and `--stdlib` narrows the rest of the way:

```bash
> bash scripts/checks/cxx-stdlibs.sh --stdlib=libc++ --compilers='clang++-18' --format=version

22.1.8
```

`--format=soname` is refused against the compiler view for the same reason:
a compiler names the headers it reaches, and headers have no `SONAME`.

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
