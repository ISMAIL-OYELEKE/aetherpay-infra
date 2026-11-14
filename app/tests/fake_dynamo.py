"""A small in-memory DynamoDB fake that evaluates the real expression strings.

It understands exactly the subset the ledger and the ADR runbook use:
SET with ``a = :v``, ``a = a + :v`` and ``a = if_not_exists(a, :z) + :v``;
conditions built from ``=``, ``<>``, ``<``, ``attribute_not_exists(x)``,
``AND``, ``OR`` and parentheses; ``#name`` placeholders. It does not model
IAM, regions or quorum: it checks expression semantics only.
"""

from __future__ import annotations

import re

from botocore.exceptions import ClientError

_TOKEN = re.compile(r"\s*(attribute_not_exists\(\s*[#\w]+\s*\)|<>|[()=<]|AND\b|OR\b|[#:]?\w+)")


def ccf():
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException", "Message": "x"}}, "Op")


def _num_or_str(av: dict):
    return int(av["N"]) if "N" in av else av["S"]


class FakeDynamo:
    def __init__(self):
        self.items: dict[tuple[str, str], dict] = {}
        self.calls: list[tuple[str, dict]] = []

    @staticmethod
    def _key(key):
        return key["pk"]["S"], key["sk"]["S"]

    # -------------------------------------------------------------- conditions
    def _check(self, item, expr, names, values):
        if not expr:
            return True
        tokens = [t for t in _TOKEN.findall(expr) if t]
        pos = 0

        def name(tok):
            return names.get(tok, tok) if tok.startswith("#") else tok

        def operand(tok):
            if tok.startswith(":"):
                return _num_or_str(values[tok])
            attr = (item or {}).get(name(tok))
            return None if attr is None else _num_or_str(attr)

        def primary():
            nonlocal pos
            tok = tokens[pos]
            pos += 1
            if tok == "(":
                v = disjunction()
                pos += 1  # ")"
                return v
            if tok.startswith("attribute_not_exists"):
                attr = name(tok[tok.index("(") + 1 : -1].strip())
                return item is None or attr not in item
            op, right = tokens[pos], tokens[pos + 1]
            pos += 2
            a, b = operand(tok), operand(right)
            if op == "=":
                return a is not None and a == b
            if op == "<>":
                return a != b
            if op == "<":
                return a is not None and a < b
            raise ValueError(op)

        def conjunction():
            nonlocal pos
            v = primary()
            while pos < len(tokens) and tokens[pos] == "AND":
                pos += 1
                v = primary() and v
            return v

        def disjunction():
            nonlocal pos
            v = conjunction()
            while pos < len(tokens) and tokens[pos] == "OR":
                pos += 1
                v = conjunction() or v
            return v

        return disjunction()

    # ------------------------------------------------------------------- API
    def put_item(self, TableName, Item, ConditionExpression=None, **_):
        self.calls.append(("put_item", Item))
        k = self._key(Item)
        if not self._check(self.items.get(k), ConditionExpression, {}, {}):
            raise ccf()
        self.items[k] = dict(Item)

    def get_item(self, TableName, Key, ConsistentRead=False):
        self.calls.append(("get_item", Key))
        item = self.items.get(self._key(Key))
        return {"Item": dict(item)} if item else {}

    def update_item(
        self,
        TableName,
        Key,
        UpdateExpression,
        ExpressionAttributeValues,
        ConditionExpression=None,
        ExpressionAttributeNames=None,
        ReturnValues="NONE",
    ):
        self.calls.append(("update_item", Key))
        names = ExpressionAttributeNames or {}
        values = ExpressionAttributeValues
        k = self._key(Key)
        cur = self.items.get(k)
        if not self._check(cur, ConditionExpression, names, values):
            raise ccf()
        new = dict(cur) if cur else {"pk": Key["pk"], "sk": Key["sk"]}
        assert UpdateExpression.startswith("SET ")
        for assignment in UpdateExpression[4:].split(", "):
            target, rhs = (p.strip() for p in assignment.split("=", 1))
            target = names.get(target, target)
            m = re.fullmatch(r"if_not_exists\(([#\w]+),\s*(:\w+)\)\s*\+\s*(:\w+)", rhs)
            if m:
                base = new.get(names.get(m[1], m[1]), values[m[2]])
                new[target] = {"N": str(int(base["N"]) + int(values[m[3]]["N"]))}
                continue
            m = re.fullmatch(r"([#\w]+)\s*\+\s*(:\w+)", rhs)
            if m:
                new[target] = {"N": str(int(new[names.get(m[1], m[1])]["N"]) + int(values[m[2]]["N"]))}
                continue
            new[target] = values[rhs]
        self.items[k] = new
        return {"Attributes": dict(new)}
