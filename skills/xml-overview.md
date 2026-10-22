---
id: xml-overview
applies-to: [dev/cajeta/codec/xml/XmlReader, dev/cajeta/codec/xml/XmlWriter, dev/cajeta/codec/xml/XmlEvent, dev/cajeta/codec/xml/XmlSource, dev/cajeta/codec/xml/XmlParseException]
title: Parse and write XML — XmlReader (pull) and XmlWriter
description: Parse XML responses (S3, OOXML) with the pull reader, stream a large document through an XmlSource, and build small request bodies with XmlWriter, with the ownership of each accessor.
---

# XML: `dev.cajeta.codec.xml`

A pull reader and a small writer for the XML web APIs speak. Not a DOM, not
XPath, no schema validation, no DTDs.

## Parse XML: the pull loop

```cajeta
import dev.cajeta.codec.xml.XmlReader;
import dev.cajeta.codec.xml.XmlEvent;

XmlReader r = heap XmlReader(body, (int64) body.count());   // reads `body` in place
int32 ev = r.next();
while (ev != XmlEvent.END_DOCUMENT) {
    if (ev == XmlEvent.START_ELEMENT && r.name().equals("Key")) {
        String key #= r.readText();      // owned; consumes through </Key>
        keys.add(#key);
    }
    ev = r.next();
}
```

Events: `START_ELEMENT` (name, attributes), `TEXT`, `END_ELEMENT` (name),
`END_DOCUMENT`. `<a/>` is a start then an end. Comments, processing
instructions, the declaration and whitespace-only text produce no event. A
CDATA section is a `TEXT` event, so adjacent text and CDATA arrive as two.

- `readText()` on a start element returns its whole text, **owned**, and
  leaves the reader on the end element. It refuses an element with a child.
- `skip()` on a start element passes its whole subtree.
- `attribute("name")` returns the value or `null`.

## Ownership

`name()`, `text()`, `attributeName(i)`, `attributeValue(i)` and
`attribute(n)` are **views** into the reader, valid until the next `next()`.
Take `readText()`, or copy (`s.substring(0, s.byteLength())`), to keep one.
`XmlReader(doc, n)` reads the caller's array in place: it must outlive the
reader.

## Names and namespaces

Names keep their prefix as written (`s3:Key`). `xmlns` and `xmlns:p` are
ordinary attributes. There is no namespace resolution, so match on the name
the producer writes. S3 writes unprefixed names under a default namespace.

## Big documents: stream through an `XmlSource`

```cajeta
public interface XmlSource { int32 read(int8[] dst, int32 off, int32 len); }  // 0 = end

XmlReader r = heap XmlReader(src, limitBytes);
```

The reader holds `XmlReader.INITIAL_BUFFER` (16 KiB) and grows only when one
tag or one text run is bigger, so memory follows the largest element, not the
document. `bufferCapacity()` reports it.

## Refusals: `XmlParseException`

Thrown with `position`, the byte offset, which the message also names:
a DOCTYPE (no DTD processing at all, so no entity expansion attacks), an
undefined entity (only `lt gt amp quot apos` and `&#N;` / `&#xH;`), an unclosed
or mismatched element, text or a second element outside the root, and a
document over the limit (`DEFAULT_LIMIT` is 16 MiB; the three-argument
constructor names another).

## Write a request body: `XmlWriter`

```cajeta
XmlWriter w = heap XmlWriter();
w.declaration();                                 // optional, first
w.start("CompleteMultipartUpload");
w.attribute("xmlns", "http://s3.amazonaws.com/doc/2006-03-01/");
w.start("Part");
w.element("ETag", etag);
w.element("PartNumber", "1");
w.end();
w.end();
int8[] body #= w.toBytes();
```

`attribute` must follow `start` directly. An element with no content closes
as `<a/>`. Text and attribute values escape `& < > "`. `end` with nothing open,
or `toString`/`toBytes` with an element still open, throws `XmlWriteException`.
