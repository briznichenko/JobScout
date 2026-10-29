from dataclasses import dataclass, field
from html import escape
from html.parser import HTMLParser


@dataclass
class Node:
    tag: str
    attrs: dict = field(default_factory=dict)
    children: list = field(default_factory=list)
    parent: object = field(default=None, repr=False)

    def walk(self):
        yield self
        for child in self.children:
            if isinstance(child, Node):
                yield from child.walk()

    def find(self, predicate):
        return next((node for node in self.walk() if predicate(node)), None)

    def has_class(self, value):
        return value in self.attrs.get("class", "").split()

    def html(self):
        if self.tag in {"script", "style", "svg", "noscript"}:
            return ""
        content = "".join(child.html() if isinstance(child, Node) else escape(child) for child in self.children)
        return f"<{self.tag}>{content}</{self.tag}>"


class Document(HTMLParser):
    void = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self, data):
        super().__init__(convert_charrefs=True)
        self.root = Node("document")
        self.current = self.root
        self.feed(data.decode("utf-8", errors="replace") if isinstance(data, bytes) else data)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs), parent=self.current)
        self.current.children.append(node)
        if tag not in self.void:
            self.current = node

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.void:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        node = self.current
        while node.parent:
            if node.tag == tag:
                self.current = node.parent
                return
            node = node.parent

    def handle_data(self, data):
        self.current.children.append(data)
