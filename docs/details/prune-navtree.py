#!/usr/bin/env python3
"""Rebuilds the generated navigation tree as a map of the site rather than an outline of every page.

Doxygen has no setting for this. MARKDOWN_ID_STYLE = GITHUB gives every heading an explicit id, and
TOC_INCLUDE_HEADINGS only adds headings that have none, so the tree carries every heading of every page
whatever those two are set to. That makes the sidebar the outline of the page being read rather than a
map of the site, where doxygen's own outline panel already lists the sections of the page being read.

The headings go, except the main page's. That page is the root of the tree rather than a node in it, so
doxygen writes its sections beside the groups instead of under it; they move under a node of their own.

The tree is spread over three kinds of file, all rewritten here:

- navtreedata.js holds `var NAVTREE`, an array of `[title, link, children]` nodes.
- A node whose children are externalized carries their variable name instead, defined in `<name>.js`.
  navtree.js maps that name to the variable by replacing `-` with `_`, which getVariable mirrors.
- navtreeindex<n>.js maps every url to its path of indices into the tree, and is regenerated from the
  pruned result. Pruning only ever removes entries, so the split across several files is collapsed to one.

Usage: prune-navtree.py <output directory>
"""

import json
import pathlib
import re
import sys

Node = list  # [title, link, children], children being a list, a variable name, or None

# The node the main page's sections move under, sitting first among the groups.
MAIN_PAGE_TITLE = "README"

# The heading doxygen-filter.py appends to a page that has children. What it lists is the pages that
# follow it in the sidebar, so it is dropped along with the rest of the navigation doxygen duplicates.
SUBPAGE_HEADING = "In this section"


def get_variable(name: str) -> str:
    """The JavaScript variable holding an externalized subtree, as navtree.js derives it."""

    variable = name.replace("-", "_")
    return f"_{variable}" if variable[:1].isdigit() else variable


def read_array(text: str, variable: str) -> list[Node]:
    match = re.search(rf"var {re.escape(variable)} =\n(\[.*?\n\]);", text, re.DOTALL)
    if match is None:
        raise SystemExit(f"no 'var {variable}' array found")
    return json.loads(match[1])


def serialize(nodes: list[Node], indent: int = 1) -> str:
    padding = "  " * indent
    chunks = []
    for title, link, children in nodes:
        head = f"{padding}[ {json.dumps(title)}, {json.dumps(link)}, "
        if isinstance(children, list):
            chunks.append(f"{head}[\n{serialize(children, indent + 1)}\n{padding}] ]")
        else:
            chunks.append(f"{head}{json.dumps(children)} ]")
    return ",\n".join(chunks)


def write_array(text: str, variable: str, nodes: list[Node]) -> str:
    body = f"var {variable} =\n[\n{serialize(nodes)}\n];"
    return re.sub(rf"var {re.escape(variable)} =\n\[.*?\n\];", lambda _: body, text, count=1, flags=re.DOTALL)


def externals(nodes: list[Node]) -> list[str]:
    """Every externalized subtree reachable from these nodes, parents before children."""

    names = []
    for _title, _link, children in nodes:
        if isinstance(children, str):
            names.append(children)
        elif isinstance(children, list):
            names.extend(externals(children))
    return names


def is_section(node: Node) -> bool:
    """Whether the node is a heading inside a page rather than a page."""

    # A grouping node carries no link of its own, and doxygen writes null for it.
    _title, link, _children = node
    return bool(link) and "#" in link


def sections_of(nodes: list[Node]) -> list[Node]:
    """The headings among these nodes, keeping the sub-headings nested under each."""

    return [node for node in nodes if is_section(node) and node[0] != SUBPAGE_HEADING]


def prune(nodes: list[Node], subtrees: dict[str, list[Node]]) -> list[Node]:
    """The nodes without the section headings."""

    kept = []
    for node in nodes:
        if is_section(node):
            continue
        title, link, children = node
        if isinstance(children, list):
            children = prune(children, subtrees) or None
        elif isinstance(children, str) and not subtrees[children]:
            children = None
        kept.append([title, link, children])
    return kept


def index_paths(nodes: list[Node], subtrees: dict[str, list[Node]], prefix: list[int]) -> dict[str, list[int]]:
    paths = {}
    for position, (_title, link, children) in enumerate(nodes):
        path = prefix + [position]
        if link:
            paths.setdefault(link, path)
        if isinstance(children, str):
            children = subtrees[children]
        if isinstance(children, list):
            paths.update(index_paths(children, subtrees, path))
    return paths


def main() -> int:
    output_directory = pathlib.Path(sys.argv[1])
    navtreedata = output_directory / "navtreedata.js"

    text = navtreedata.read_text(encoding="utf-8")
    tree = read_array(text, "NAVTREE")

    # The root node is the project itself, and the index addresses it with an empty path,
    # so every path below is relative to it rather than to the array holding it.
    if len(tree) != 1:
        raise SystemExit(f"expected a single root node, found {len(tree)}")

    root_title, root_link, root_children = tree[0]
    if not isinstance(root_children, list):
        raise SystemExit("the root's children are externalized, and the main page's node is built from them")

    # Parents are read before the subtrees they reference, so reversing the order below walks children first.
    subtrees: dict[str, list[Node]] = {}
    pending = externals(tree)
    while pending:
        name = pending.pop(0)
        if name in subtrees:
            continue
        subtrees[name] = read_array((output_directory / f"{name}.js").read_text(encoding="utf-8"), get_variable(name))
        pending.extend(externals(subtrees[name]))

    for name in reversed(list(subtrees)):
        subtrees[name] = prune(subtrees[name], subtrees)

    children = [[MAIN_PAGE_TITLE, root_link, sections_of(root_children)]] + prune(root_children, subtrees)
    tree = [[root_title, root_link, children]]

    paths = index_paths(children, subtrees, [])

    # The main page is addressed twice, as the root and as the node holding its sections. The root is the
    # one the index keeps: landing on the main page then leaves the sidebar as it is, where resolving to
    # the node would open the thirteen sections under it.
    paths[root_link] = []

    # Doxygen writes pages.html when a page hangs off nothing, which is what a markdown file absent from
    # HIERARCHY does. It is no node of the tree, and doxygen still maps it, so that landing there expands nothing.
    if (output_directory / "pages.html").exists():
        paths.setdefault("pages.html", [])

    for name, nodes in subtrees.items():
        path = output_directory / f"{name}.js"
        if nodes:
            path.write_text(write_array(path.read_text(encoding="utf-8"), get_variable(name), nodes), encoding="utf-8")
        else:
            path.unlink()

    entries = ",\n".join(f'"{url}":[{",".join(map(str, path))}]' for url, path in sorted(paths.items()))
    (output_directory / "navtreeindex0.js").write_text(f"var NAVTREEINDEX0 =\n{{\n{entries}\n}};\n", encoding="utf-8")
    for stale in output_directory.glob("navtreeindex[1-9]*.js"):
        stale.unlink()

    text = write_array(text, "NAVTREE", tree)
    text = re.sub(r"var NAVTREEINDEX =\n\[.*?\n\];",
                  lambda _: f'var NAVTREEINDEX =\n[\n{json.dumps(min(paths))}\n];',
                  text, count=1, flags=re.DOTALL)
    navtreedata.write_text(text, encoding="utf-8")

    print(f"navigation tree: {len(paths)} entries, {len(children)} at the top level")
    return 0


if __name__ == "__main__":
    sys.exit(main())
