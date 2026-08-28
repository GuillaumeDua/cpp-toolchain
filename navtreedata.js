/*
 @licstart  The following is the entire license notice for the JavaScript code in this file.

 The MIT License (MIT)

 Copyright (C) 1997-2020 by Dimitri van Heesch

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 and associated documentation files (the "Software"), to deal in the Software without restriction,
 including without limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

 @licend  The above is the entire license notice for the JavaScript code in this file
*/
var NAVTREE =
[
  [ "cpp-toolchain", "index.html", [
    [ "Pick your image (one per stage)", "index.html#pick-your-image-one-per-stage", null ],
    [ "Quick start", "index.html#quick-start", null ],
    [ "🌟 Key features", "index.html#autotoc_md-key-features", null ],
    [ "What's inside", "index.html#whats-inside", null ],
    [ "Tags &amp; versioning", "index.html#tags--versioning", [
      [ "What's inside a given tag", "index.html#whats-inside-a-given-tag", null ]
    ] ],
    [ "As a dev environment", "index.html#as-a-dev-environment", null ],
    [ "Standalone use (no Docker)", "index.html#standalone-use-no-docker", null ],
    [ "Build it yourself", "index.html#build-it-yourself", null ],
    [ "Compilers &amp; standard library", "index.html#compilers--standard-library", null ],
    [ "Going further", "index.html#going-further", null ],
    [ "Dependency updates", "index.html#dependency-updates", null ],
    [ "Contributing", "index.html#contributing", null ],
    [ "License", "index.html#license", null ],
    [ "Code coverage", "md_docs_2COVERAGE.html", [
      [ "See also", "md_docs_2COVERAGE.html#see-also", null ]
    ] ],
    [ "Cross-architecture compilation &amp; multilib", "md_docs_2CROSS-COMPILATION.html", [
      [ "Cross-architecture compilation", "md_docs_2CROSS-COMPILATION.html#cross-architecture-compilation", [
        [ "Published targets", "md_docs_2CROSS-COMPILATION.html#published-targets", null ],
        [ "Capabilities", "md_docs_2CROSS-COMPILATION.html#capabilities", null ]
      ] ],
      [ "Multilib - secondary ABIs", "md_docs_2CROSS-COMPILATION.html#multilib---secondary-abis", null ],
      [ "See also", "md_docs_2CROSS-COMPILATION.html#see-also-1", null ]
    ] ],
    [ "Documentation site", "md_docs_2details_2README.html", [
      [ "Rendering it locally", "md_docs_2details_2README.html#rendering-it-locally", null ],
      [ "When something is wrong", "md_docs_2details_2README.html#when-something-is-wrong", null ],
      [ "The pieces", "md_docs_2details_2README.html#the-pieces", null ],
      [ "Where the site differs from GitHub", "md_docs_2details_2README.html#where-the-site-differs-from-github", null ]
    ] ],
    [ "Using cpp-toolchain as a dev environment", "md_docs_2DEVCONTAINER.html", [
      [ "Reopen in Container", "md_docs_2DEVCONTAINER.html#reopen-in-container", null ],
      [ "Remote SSH", "md_docs_2DEVCONTAINER.html#remote-ssh", [
        [ "1. Build and start the SSH service", "md_docs_2DEVCONTAINER.html#autotoc_md1-build-and-start-the-ssh-service", null ],
        [ "2. Connect from VS Code", "md_docs_2DEVCONTAINER.html#autotoc_md2-connect-from-vs-code", null ]
      ] ],
      [ "See also", "md_docs_2DEVCONTAINER.html#see-also-2", null ]
    ] ],
    [ "Images validation", "md_docs_2IMAGES__VALIDATION.html", [
      [ "The two rules", "md_docs_2IMAGES__VALIDATION.html#the-two-rules", [
        [ "1 - No version number is written down", "md_docs_2IMAGES__VALIDATION.html#autotoc_md1---no-version-number-is-written-down", null ],
        [ "2 - What is installed is discovered, not declared", "md_docs_2IMAGES__VALIDATION.html#autotoc_md2---what-is-installed-is-discovered-not-declared", null ]
      ] ],
      [ "Where it runs", "md_docs_2IMAGES__VALIDATION.html#where-it-runs", null ],
      [ "What is checked", "md_docs_2IMAGES__VALIDATION.html#what-is-checked", [
        [ "Parity: the same library on both sides", "md_docs_2IMAGES__VALIDATION.html#parity-the-same-library-on-both-sides", null ]
      ] ],
      [ "The scripts", "md_docs_2IMAGES__VALIDATION.html#the-scripts", [
        [ "Standards detection", "md_docs_2IMAGES__VALIDATION.html#standards-detection", null ]
      ] ],
      [ "In CI", "md_docs_2IMAGES__VALIDATION.html#in-ci", null ],
      [ "Running it locally", "md_docs_2IMAGES__VALIDATION.html#running-it-locally", null ],
      [ "Proving the gate can fail", "md_docs_2IMAGES__VALIDATION.html#proving-the-gate-can-fail", null ],
      [ "What this deliberately does not check", "md_docs_2IMAGES__VALIDATION.html#what-this-deliberately-does-not-check", null ]
    ] ],
    [ "Release process", "md_docs_2RELEASE__PROCESS.html", [
      [ "In a nutshell", "md_docs_2RELEASE__PROCESS.html#in-a-nutshell", [
        [ "Promoting that rc as a major instead", "md_docs_2RELEASE__PROCESS.html#promoting-that-rc-as-a-major-instead", null ],
        [ "What you cannot do", "md_docs_2RELEASE__PROCESS.html#what-you-cannot-do", null ]
      ] ],
      [ "The model", "md_docs_2RELEASE__PROCESS.html#the-model", null ],
      [ "The normal path", "md_docs_2RELEASE__PROCESS.html#the-normal-path", null ],
      [ "Urgent fixes", "md_docs_2RELEASE__PROCESS.html#urgent-fixes", null ],
      [ "Rollback", "md_docs_2RELEASE__PROCESS.html#rollback", null ],
      [ "Cutting a major", "md_docs_2RELEASE__PROCESS.html#cutting-a-major", [
        [ "From a validated rc", "md_docs_2RELEASE__PROCESS.html#from-a-validated-rc", null ],
        [ "From a commit no rc was built at", "md_docs_2RELEASE__PROCESS.html#from-a-commit-no-rc-was-built-at", null ]
      ] ],
      [ "What the release process assumes", "md_docs_2RELEASE__PROCESS.html#what-the-release-process-assumes", [
        [ "Setup prerequisites", "md_docs_2RELEASE__PROCESS.html#setup-prerequisites", null ]
      ] ],
      [ "Failure modes", "md_docs_2RELEASE__PROCESS.html#failure-modes", null ]
    ] ],
    [ "How to contribute", "md_HOW__TO__CONTRIBUTE.html", [
      [ "The two workflows", "md_HOW__TO__CONTRIBUTE.html#the-two-workflows", null ],
      [ "Opening a pull request", "md_HOW__TO__CONTRIBUTE.html#opening-a-pull-request", null ],
      [ "What the build gate checks", "md_HOW__TO__CONTRIBUTE.html#what-the-build-gate-checks", null ],
      [ "How images get published", "md_HOW__TO__CONTRIBUTE.html#how-images-get-published", null ],
      [ "Related docs", "md_HOW__TO__CONTRIBUTE.html#related-docs", null ]
    ] ],
    [ "releases/", "md_releases_2README.html", [
      [ "Additional resources", "md_releases_2README.html#additional-resources", null ]
    ] ],
    [ "Check scripts", "md_scripts_2checks_2README.html", [
      [ "Standalone", "md_scripts_2checks_2README.html#standalone", [
        [ "<span class=\"tt\">cxx-standards.sh</span>", "md_scripts_2checks_2README.html#cxx-standardssh", null ],
        [ "<span class=\"tt\">cxx-stdlibs.sh</span>", "md_scripts_2checks_2README.html#cxx-stdlibssh", [
          [ "The two views", "md_scripts_2checks_2README.html#the-two-views", null ]
        ] ]
      ] ],
      [ "<a href=\"https://github.com/GuillaumeDua/cpp-toolchain/tree/main/scripts/checks/details\">details/</a>", "md_scripts_2checks_2README.html#detailshttpsgithubcomguillaumeduacpp-toolchaintreemainscriptschecksdetails", null ]
    ] ],
    [ "Repository tooling", "md_scripts_2details_2README.html", null ],
    [ "Toolchain installation scripts", "md_scripts_2install_2README.html", [
      [ "<span class=\"tt\">cmake.sh</span>", "md_scripts_2install_2README.html#cmakesh", null ],
      [ "<span class=\"tt\">gcc.sh</span>", "md_scripts_2install_2README.html#gccsh", null ],
      [ "<span class=\"tt\">llvm.sh</span>", "md_scripts_2install_2README.html#llvmsh", null ],
      [ "<span class=\"tt\">binutils.sh</span>", "md_scripts_2install_2README.html#binutilssh", null ],
      [ "<span class=\"tt\">doxygen.sh</span>", "md_scripts_2install_2README.html#doxygensh", null ]
    ] ],
    [ "Scripts", "md_scripts_2README.html", [
      [ "Using a public script on its own", "md_scripts_2README.html#using-a-public-script-on-its-own", null ]
    ] ]
  ] ]
];

var NAVTREEINDEX =
[
"index.html"
];

const SYNCONMSG = 'click to disable panel synchronization';
const SYNCOFFMSG = 'click to enable panel synchronization';
const LISTOFALLMEMBERS = 'List of all members';