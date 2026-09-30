"""Import a sibling script whose filename a normal `import` cannot spell.

The tools here are hyphenated commands rather than modules, so the ones that share code reach it
through importlib. This file has no hyphen, and Python puts the running script's own directory on
sys.path, so importing it needs no path handling of its own.

Set `sys.dont_write_bytecode = True` before importing this, or a `__pycache__` lands beside the sources.
"""

import importlib.util
import pathlib

HERE = pathlib.Path(__file__).resolve().parent


def load(stem):
    """`<stem>.py` from this directory, imported by path - the hyphen makes it not a module name."""
    spec = importlib.util.spec_from_file_location(stem.replace("-", "_"), HERE / f"{stem}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
