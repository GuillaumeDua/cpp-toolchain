# Code coverage

Both ecosystems are supported.
They are **not** interchangeable:

- `gcov`/`lcov` read GCC counters (`.gcno` / `.gcda`)
- `llvm-cov`/`llvm-profdata` read Clang's (`.profraw` / `.profdata`)

| Tool                        | Toolchain |     `build`      | `static-analysis` | `documentation` | `dev` |
| --------------------------- | --------- | :--------------: | :---------------: | :-------------: | :---: |
| `gcov`, `gcov-tool`         | GNU       |        ✅        |        ✅         |       ✅        |  ✅   |
| `lcov`, `genhtml`           | GNU       |                  |                   |       ✅        |  ✅   |
| `llvm-cov`, `llvm-profdata` | LLVM      |                  |        ✅         |       ✅        |  ✅   |

```bash
# GNU: gcov counters -> lcov/genhtml HTML report
g++ --coverage main.cpp -o app && ./app
lcov --capture --directory . --output-file cov.info && genhtml cov.info --output-directory html

# LLVM: instrumented profile -> llvm-profdata -> llvm-cov
clang++ -fprofile-instr-generate -fcoverage-mapping main.cpp -o app
LLVM_PROFILE_FILE=app.profraw ./app
llvm-profdata merge -sparse app.profraw -o app.profdata
llvm-cov show ./app -instr-profile=app.profdata
```

`build` installs Clang minimalistically, which stops short of the `llvm-<N>` package that carries `llvm-cov` and `llvm-profdata`, so neither is present there in any form.
`static-analysis` pulls them in transitively through the full LLVM toolchain, `documentation` installs `llvm-<N>` outright, and both register the unversioned commands.
`lcov` (the Perl frontend producing HTML) ships in the coverage-oriented stages only - `gcov` itself always comes with GCC.

> [!TIP] llvm-cov compatibility mode
> `llvm-cov` can also read GCC-style counters via its `llvm-cov gcov` compatibility mode, so `lcov --gcov-tool "llvm-cov gcov"` bridges Clang-compiled coverage into an `lcov` report.

## See also

- [README.md](../README.md) - images, features, tags, build arguments.
- [docs/CROSS-COMPILATION.md](CROSS-COMPILATION.md) - cross-architecture compilation and multilib.
