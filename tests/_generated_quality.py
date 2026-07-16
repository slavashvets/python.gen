from __future__ import annotations

import ast
import io
import tokenize
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class LongLine:
    path: Path
    line_number: int
    length: int

    def label(self) -> str:
        return f"{self.path}:{self.line_number}:{self.length}"


def _module_sql_interior_lines(source: str) -> set[int]:
    tree = ast.parse(source)
    spans = {
        (node.value.lineno, node.value.col_offset, node.value.end_lineno, node.value.end_col_offset)
        for node in tree.body
        if isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id == "SQL"
        and isinstance(node.value, ast.Constant)
        and isinstance(node.value.value, str)
        and node.value.end_lineno is not None
        and node.value.end_col_offset is not None
    }
    string_tokens = (
        token for token in tokenize.generate_tokens(io.StringIO(source).readline) if token.type == tokenize.STRING
    )
    return {
        line_number
        for token in string_tokens
        if (*token.start, *token.end) in spans
        for line_number in range(token.start[0] + 1, token.end[0])
    }


def generated_line_length_issues(path: Path, *, limit: int = 120) -> tuple[list[LongLine], list[LongLine]]:
    source = path.read_text()
    sql_interior = _module_sql_interior_lines(source)
    authored: list[LongLine] = []
    sql: list[LongLine] = []
    for line_number, line in enumerate(source.splitlines(), start=1):
        if len(line) <= limit:
            continue
        issue = LongLine(path, line_number, len(line))
        (sql if line_number in sql_interior else authored).append(issue)
    return authored, sql
