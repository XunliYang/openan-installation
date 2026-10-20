# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Mermaid blocks in the docs must survive GitHub's rendering pipeline.

GitHub decodes HTML entities inside mermaid fences BEFORE parsing, so
entities like &lt; or &#91; re-introduce the very characters they were
escaping and break the parser. Multi-target edges written as "A --> B or C"
are invalid syntax, and unquoted labels must not carry bracket-like
characters (<br/> tags excepted). Real rendering (mermaid-cli) is not
available in CI; these structural rules catch the failure classes the docs
actually hit.
"""
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
SPECIALS = "()<>[]{}"


def strip_br(label):
    return re.sub(r"<br\s*/?>", "", label)


def mermaid_blocks():
    for doc in sorted(DOCS.glob("*-architecture.md")):
        text = doc.read_text(encoding="utf-8")
        for index, block in enumerate(re.findall(r"```mermaid\r?\n(.*?)```", text, re.S)):
            yield pytest.param(doc.name, index, block, id=f"{doc.name}:{index}")


BLOCKS = list(mermaid_blocks())


@pytest.mark.parametrize("doc,index,block", BLOCKS)
def test_mermaid_blocks_have_no_html_entities(doc, index, block):
    offenders = re.findall(r"&[a-zA-Z#][a-zA-Z0-9]*;", block)
    assert not offenders, (
        f"{doc} block {index}: HTML entities {offenders} are decoded by GitHub "
        "before mermaid parsing and break the diagram; use quoted labels instead"
    )


@pytest.mark.parametrize("doc,index,block", BLOCKS)
def test_mermaid_edges_have_no_or_targets(doc, index, block):
    # "A --> B or C" is invalid syntax; "or" inside node/edge LABELS is fine.
    for line in block.splitlines():
        if "-->" not in line:
            continue
        target_side = line.split("-->", 1)[1]
        target_side = re.sub(r"\|[^|]*\|", " ", target_side)  # drop edge labels
        if re.search(r"\bor\b", target_side):
            raise AssertionError(
                f"{doc} block {index}: invalid multi-target edge (use '&' or "
                f"separate edges): {line.strip()}"
            )


@pytest.mark.parametrize("doc,index,block", BLOCKS)
def test_mermaid_edge_labels_quote_specials(doc, index, block):
    for line in block.splitlines():
        for label in re.findall(r"-->?\|([^|]*)\|", line):
            if any(ch in SPECIALS for ch in strip_br(label)):
                assert label.startswith('"') and label.endswith('"'), (
                    f"{doc} block {index}: unquoted edge label with special "
                    f"characters breaks the parser: |{label}|"
                )


@pytest.mark.parametrize("doc,index,block", BLOCKS)
def test_mermaid_node_labels_quote_brackets(doc, index, block):
    for line in block.splitlines():
        for label in re.findall(r"\[([^\"\\\]]*)\]", line):
            # [(text)] is the valid cylinder (database) form; check its inner text
            if label.startswith("(") and label.endswith(")"):
                label = label[1:-1]
            if any(ch in SPECIALS for ch in strip_br(label)):
                raise AssertionError(
                    f"{doc} block {index}: unquoted node label with bracket-like "
                    f"characters breaks the parser: [{label}]"
                )
