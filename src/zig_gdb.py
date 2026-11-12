# gdb pretty printers for Zig values, loaded by zile's debugger.
#
# gdb has no Zig support: a slice shows as a pointer and a length, and the
# optionals, error unions and tagged unions of Zig's own backend (the default
# for debug builds) can't be read at all, as gdb gets their size wrong. These
# read each part at its own address instead. Both backends' layouts are known
# (Zig's own: `has_value` / `is_error` / `tag` beside the payload fields;
# LLVM's: `payload` with `some` / `error` / `tag`).

import gdb
import gdb.printing

MAX_TEXT = 200
MAX_ITEMS = 100


def part(val, f):
    """Field `f` of `val`, read at its own address when `val` has one."""
    if val.address is not None:
        at = val.address.cast(gdb.lookup_type("char").pointer()) + f.bitpos // 8
        return at.cast(f.type.pointer()).dereference()
    return val[f]


def fields(val):
    return {f.name: f for f in val.type.strip_typedefs().fields() if f.name}


def is_byte(t):
    t = t.strip_typedefs().unqualified()
    return t.sizeof == 1 and t.code in (gdb.TYPE_CODE_INT, gdb.TYPE_CODE_CHAR)


class Text:
    """Something with nothing inside: `null`, `error.Oops`, a string."""

    def __init__(self, text):
        self.text = text

    def to_string(self):
        return self.text


class Slice:
    def __init__(self, ptr, length):
        self.ptr = ptr
        self.len = length

    def to_string(self):
        return "len %d" % self.len

    def display_hint(self):
        return "array"

    def children(self):
        for i in range(min(self.len, MAX_ITEMS)):
            yield "[%d]" % i, (self.ptr + i).dereference()


def text(ptr, length):
    n = min(length, MAX_TEXT)
    raw = bytes(gdb.selected_inferior().read_memory(ptr, n)) if n > 0 else b""
    out = '"' + raw.decode("utf-8", "backslashreplace").translate(ESCAPES) + '"'
    if n < length:
        out += "… (len %d)" % length
    return Text(out)


ESCAPES = {ord("\n"): "\\n", ord("\r"): "\\r", ord("\t"): "\\t", ord('"'): '\\"', 0: "\\0"}


class Tagged:
    """A tagged union: `.tag`, and its payload inside."""

    def __init__(self, name, payload):
        self.name = name
        self.payload = payload

    def to_string(self):
        return "." + self.name

    def children(self):
        if self.payload is not None:
            yield self.name, self.payload


def inner(val):
    """The printer of what an optional or an error union holds."""
    return lookup(val) or gdb.printing.make_visualizer(val)


def tag_name(tag):
    # `green`, or `t.E.green`.
    return str(tag).rsplit(".", 1)[-1]


def lookup(val):
    try:
        t = val.type.strip_typedefs()
        if t.code not in (gdb.TYPE_CODE_STRUCT, gdb.TYPE_CODE_UNION):
            return None
        fs = fields(val)
        names = set(fs)
        # By Zig's names for its types, so C and Rust values are left alone.
        kind = (t.name or "")[:1]
        if kind == "[" and names == {"ptr", "len"} and fs["ptr"].type.code == gdb.TYPE_CODE_PTR:
            ptr, length = part(val, fs["ptr"]), int(part(val, fs["len"]))
            if is_byte(ptr.type.target()):
                return text(ptr, length)
            return Slice(ptr, length)
        # Optionals. Zig's own backend: `has_value`, `null`, `?`.
        if kind == "?" and "has_value" in names and "?" in names:
            if int(part(val, fs["has_value"])) == 0:
                return Text("null")
            return inner(part(val, fs["?"]))
        if kind == "?" and names == {"payload", "some"}:
            if int(part(val, fs["some"])) == 0:
                return Text("null")
            return inner(part(val, fs["payload"]))
        # Error unions.
        bang = "!" in (t.name or "")
        if bang and "is_error" in names and "error" in names and "value" in names:
            if int(part(val, fs["is_error"])) != 0:
                return Text("error." + tag_name(part(val, fs["error"])))
            return inner(part(val, fs["value"]))
        if bang and names == {"error", "payload"}:
            err = part(val, fs["error"])
            if int(err) != 0:
                return Text("error." + tag_name(err))
            return inner(part(val, fs["payload"]))
        # Tagged unions: every tag has a payload field of its name.
        if "tag" in names and fs["tag"].type.strip_typedefs().code == gdb.TYPE_CODE_ENUM:
            tag = part(val, fs["tag"])
            box = part(val, fs["payload"]) if names == {"payload", "tag"} else val
            inside = fields(box)
            tags = [tag_name(f.name) for f in fs["tag"].type.strip_typedefs().fields()]
            if not tags or any(x not in inside for x in tags):
                return None
            name = tag_name(tag)
            if name not in inside:
                return None
            payload = part(box, inside[name])
            if payload.type.strip_typedefs().code == gdb.TYPE_CODE_VOID:
                payload = None
            return Tagged(name, payload)
    except Exception:
        return None
    return None


gdb.pretty_printers.append(lookup)
