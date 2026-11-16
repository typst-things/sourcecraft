// =============================================================================
// sourcecraft — Rust Grammar
// =============================================================================
// Rust is not "class based", so the grammar maps its constructs onto UML:
//
//   struct            → class       (fields = attributes)
//   enum              → enum        (variants = constants)
//   trait             → interface   (required methods are shown in italics)
//   impl Type         → methods are attached to `Type`
//   impl Trait for T  → implementation relation  T ─▷ Trait
//   trait A: B        → inheritance relation     A ─▷ B   (supertrait)
//
// Relation inference rules (ownership-aware):
//   1. A field of an owned type (`Foo`, `Box<Foo>`, `Vec<Foo>`, `Option<Foo>`)
//      → composition  (label = field name)
//   2. A field behind a reference or shared pointer (`&Foo`, `Rc<Foo>`,
//      `Arc<Foo>`, `Weak<Foo>`, `*const Foo`) → aggregation
//   3. Enum variant payloads follow the same rules (label = variant name)
//   4. A method parameter of type `Foo` that is not already a field relation
//      → dependency (label = method name)
//
// Only relations between types present in the parsed source are emitted, so
// std traits such as `Display` or `Debug` never produce dangling arrows.
//
// Layout can be injected with `#[layout(level = 0, order = 1)]` (or the
// `@Layout(level=0, order=1)` form shared with the other grammars).
//
// TYPST GOTCHA: closures/inner-functions cannot mutate outer-scope variables.
// All accumulation is therefore done inline inside `parse`; the helpers
// below are pure functions.

#import "../ir.typ"

// ---------------------------------------------------------------------------
// Lexical helpers (pure)
// ---------------------------------------------------------------------------

#let _ws(s) = s.replace(regex("\\s+"), " ").trim()

#let _is-ident-char(c) = c != "" and c.match(regex("^[A-Za-z0-9_]$")) != none

/// `array.join()` returns `none` for an empty array; always yield a string.
#let _cat(parts) = if parts.len() == 0 { "" } else { parts.join() }

#let _is-newline(c) = c == "\n" or c == "\r\n"

/// Remove `//` and (nested) `/* */` comments, and blank the contents of
/// string, raw-string and char literals. Lifetimes (`'a`) are preserved.
/// Newlines are kept so the line structure survives.
#let strip-comments(source) = {
  let chars = source.clusters()
  let n = chars.len()
  let out = ()
  let i = 0

  while i < n {
    let ch = chars.at(i)
    let next = if i + 1 < n { chars.at(i + 1) } else { "" }
    let prev = if i > 0 { chars.at(i - 1) } else { "" }

    if ch == "/" and next == "/" {
      i += 2
      while i < n and not _is-newline(chars.at(i)) { i += 1 }
    } else if ch == "/" and next == "*" {
      let depth = 1
      i += 2
      out.push(" ")
      while i < n and depth > 0 {
        let c = chars.at(i)
        let nx = if i + 1 < n { chars.at(i + 1) } else { "" }
        if c == "/" and nx == "*" {
          depth += 1
          i += 2
        } else if c == "*" and nx == "/" {
          depth -= 1
          i += 2
        } else {
          if _is-newline(c) { out.push(c) }
          i += 1
        }
      }
    } else if (
      ch == "r"
        and (
          not _is-ident-char(prev)
            or (prev == "b" and (i < 2 or not _is-ident-char(chars.at(i - 2))))
        )
        and (next == "\"" or next == "#")
    ) {
      // Possible raw string: r"..." / r#"..."# / br"..."
      let j = i + 1
      let hashes = 0
      while j < n and chars.at(j) == "#" {
        hashes += 1
        j += 1
      }
      if j < n and chars.at(j) == "\"" {
        out.push("\"")
        j += 1
        let closed = false
        while j < n and not closed {
          let c = chars.at(j)
          if c == "\"" {
            let ok = true
            for h in range(hashes) {
              if j + 1 + h >= n or chars.at(j + 1 + h) != "#" { ok = false }
            }
            if ok {
              closed = true
              j += 1 + hashes
            } else {
              j += 1
            }
          } else {
            if _is-newline(c) { out.push(c) }
            j += 1
          }
        }
        out.push("\"")
        i = j
      } else {
        // Just an identifier starting with `r` (e.g. `r#type` raw ident)
        out.push(ch)
        i += 1
      }
    } else if ch == "\"" {
      out.push("\"")
      i += 1
      while i < n and chars.at(i) != "\"" {
        let c = chars.at(i)
        if c == "\\" {
          if i + 1 < n and _is-newline(chars.at(i + 1)) { out.push(chars.at(i + 1)) }
          i += 2
        } else {
          if _is-newline(c) { out.push(c) }
          i += 1
        }
      }
      out.push("\"")
      i += 1
    } else if ch == "'" {
      if next == "\\" {
        // Escaped char literal: '\n', '\'', '\u{1F600}'
        let j = i + 3
        while j < n and chars.at(j) != "'" and not _is-newline(chars.at(j)) { j += 1 }
        out.push("''")
        i = j + 1
      } else if i + 2 < n and chars.at(i + 2) == "'" {
        out.push("''")
        i += 3
      } else {
        // Lifetime or label: keep as is
        out.push(ch)
        i += 1
      }
    } else {
      out.push(ch)
      i += 1
    }
  }

  _cat(out)
}

/// Split `text` into top-level items. Each item is `(header, body)`:
/// the text before the `{ ... }` block (or before `;`), and the block
/// contents (`none` for `;`-terminated items such as `use` or trait methods
/// without a default body).
#let _scan-items(text) = {
  let chars = text.clusters()
  let n = chars.len()
  let items = ()
  let buf = ""
  let pd = 0
  let i = 0

  while i < n {
    let ch = chars.at(i)
    if ch == "{" and pd == 0 {
      let depth = 1
      let j = i + 1
      while j < n and depth > 0 {
        let c = chars.at(j)
        if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
        j += 1
      }
      let body = _cat(chars.slice(i + 1, calc.max(i + 1, j - 1)))
      items.push((header: buf.trim(), body: body))
      buf = ""
      i = j
      // Consume an optional `;` that terminates the item (`const X: T = T { .. };`)
      let k = i
      while k < n and chars.at(k).match(regex("^\\s+$")) != none { k += 1 }
      if k < n and chars.at(k) == ";" { i = k + 1 }
    } else if ch == ";" and pd == 0 {
      items.push((header: buf.trim(), body: none))
      buf = ""
      i += 1
    } else {
      if ch == "(" or ch == "[" { pd += 1 } else if ch == ")" or ch == "]" { pd = calc.max(0, pd - 1) }
      buf += ch
      i += 1
    }
  }

  items
}

/// Split on commas that are not nested in (), [], {} or <>.
/// `->` and `=>` are not treated as closing angle brackets.
#let _split-commas(text) = {
  let parts = ()
  let cur = ""
  let depth = 0
  let prev = ""

  for ch in text.clusters() {
    if ch == "," and depth == 0 {
      parts.push(cur.trim())
      cur = ""
    } else {
      if ch == "(" or ch == "[" or ch == "{" or ch == "<" {
        depth += 1
      } else if ch == ")" or ch == "]" or ch == "}" {
        depth = calc.max(0, depth - 1)
      } else if ch == ">" and prev != "-" and prev != "=" {
        depth = calc.max(0, depth - 1)
      }
      cur += ch
    }
    prev = ch
  }

  if cur.trim() != "" { parts.push(cur.trim()) }
  parts.filter(p => p != "")
}

/// `text` must start with `open`. Returns `(inner, rest)` for the balanced
/// group, or `none` when it is not closed.
#let _take-group(text, open, close) = {
  if not text.starts-with(open) { return none }
  let chars = text.clusters()
  let depth = 0
  let prev = ""
  for (i, ch) in chars.enumerate() {
    if ch == open {
      depth += 1
    } else if ch == close and not (close == ">" and (prev == "-" or prev == "=")) {
      depth -= 1
      if depth == 0 {
        return (
          inner: _cat(chars.slice(1, i)).trim(),
          rest: _cat(chars.slice(i + 1)),
        )
      }
    }
    prev = ch
  }
  none
}

// ---------------------------------------------------------------------------
// Semantic helpers (pure)
// ---------------------------------------------------------------------------

/// Names of the generic parameters declared in `<...>` content: `'a, T: Display, const N: usize` → ("T", "N")
#let _generic-names(generics) = {
  if generics == none or generics == "" { return () }
  let names = ()
  for part in _split-commas(generics) {
    if part.starts-with("'") { continue }
    let p = part.replace(regex("^const\\s+"), "")
    let m = p.match(regex("^[A-Za-z_]\\w*"))
    if m != none { names.push(m.text) }
  }
  names
}

/// Named (CamelCase) user types mentioned in a Rust type expression, ignoring
/// primitives, std containers (they are lowercase-initial or listed below)
/// and the names in `ignore` (generic parameters).
#let _std-types = (
  "Self", "String", "Vec", "Option", "Box", "Result", "Rc", "Arc", "Weak",
  "RefCell", "Cell", "Mutex", "RwLock", "HashMap", "HashSet", "BTreeMap",
  "BTreeSet", "VecDeque", "BinaryHeap", "Cow", "PhantomData", "Pin", "Fn",
  "FnMut", "FnOnce", "Send", "Sync", "Sized", "Copy", "Clone", "Debug",
  "Default", "Display", "Path", "PathBuf", "Duration", "Instant", "Ordering",
)

#let _type-refs(type-text, ignore) = {
  let t = type-text.replace(regex("'\\w+"), " ")
  let names = ()
  for m in t.matches(regex("[A-Za-z_]\\w*(?:::[A-Za-z_]\\w*)*")) {
    let last = m.text.split("::").last()
    if (
      last.match(regex("^[A-Z]")) != none
        and last not in _std-types
        and last not in ignore
        and last not in names
    ) {
      names.push(last)
    }
  }
  names
}

/// References, raw pointers and Rc/Arc/Weak do not own their target.
#let _is-shared(type-text) = {
  type-text.match(regex("&|\\*(?:const|mut)\\b|\\b(?:Rc|Arc|Weak)\\s*<")) != none
}

/// `pub` → public · `pub(crate)`/`pub(super)`/`pub(in …)` → package · none → private
#let _visibility(prefix) = {
  if prefix.match(regex("\\bpub\\s*\\(")) != none { "package" }
  else if prefix.match(regex("\\bpub\\b")) != none { "public" }
  else { "private" }
}

#let _strip-attrs(text) = text.replace(regex("#!?\\[[^\\]]*\\]"), " ").trim()

/// Pull `#[layout(level = N, order = M)]` / `@Layout(level=N, order=M)` out of a
/// header. Returns `(header: <header without attributes>, level, order)`.
#let _extract-layout(header) = {
  let level = none
  let order = none
  let lm = header.match(regex("(?i)(?:#!?\\[\\s*|@)layout\\s*\\(([^)]*)\\)\\s*\\]?"))
  if lm != none {
    let params = lm.captures.at(0)
    let level-m = params.match(regex("(?i)level\\s*=\\s*(\\d+)"))
    let order-m = params.match(regex("(?i)order\\s*=\\s*(\\d+)"))
    if level-m != none { level = int(level-m.captures.at(0)) }
    if order-m != none { order = int(order-m.captures.at(0)) }
  }
  let cleaned = header.replace(regex("(?i)@layout\\s*\\([^)]*\\)"), " ")
  (header: _ws(_strip-attrs(cleaned)), level: level, order: order)
}

/// Parse a function signature header (`pub async fn name<T>(a: A) -> R where ...`).
/// Returns `none` when the header is not a function.
#let _parse-fn(header) = {
  let h = _ws(header)
  let m = h.match(regex("\\bfn\\s+([A-Za-z_]\\w*)"))
  if m == none { return none }

  let prefix = h.slice(0, m.start)
  let rest = h.slice(m.end).trim()
  let generics = ""
  if rest.starts-with("<") {
    let g = _take-group(rest, "<", ">")
    if g == none { return none }
    generics = g.inner
    rest = g.rest.trim()
  }
  let g = _take-group(rest, "(", ")")
  if g == none { return none }

  let after = g.rest.trim()
  let ret = none
  let rm = after.match(regex("^->\\s*(.*)$"))
  if rm != none {
    ret = rm.captures.at(0).split(regex("\\bwhere\\b")).at(0).trim()
    if ret == "" or ret == "()" { ret = none }
  }

  let params = ()
  let has-self = false
  for p in _split-commas(g.inner) {
    let p = _strip-attrs(_ws(p))
    if p.match(regex("^(?:&\\s*(?:'\\w+\\s+)?)?(?:mut\\s+)?self\\b")) != none {
      has-self = true
    } else if p != "" {
      params.push(p)
    }
  }

  (
    name: m.captures.at(0),
    visibility: _visibility(prefix),
    generics: generics,
    params: params,
    ret: ret,
    has-self: has-self,
  )
}

/// Last path segment of a type/trait path with generics removed:
/// `std::fmt::Display` → `Display`, `From<Foo>` → `From`, `&mut Foo<T>` → `Foo`.
#let _base-name(text) = {
  let t = text.replace(regex("^[&*]\\s*(?:'\\w+\\s+)?(?:mut\\s+|const\\s+)?"), "")
  t = t.replace(regex("^dyn\\s+"), "")
  let lt = t.position("<")
  if lt != none { t = t.slice(0, lt) }
  t.trim().split("::").last().trim()
}

/// Strip leading visibility and optional qualifiers; returns `(prefix, rest)`.
#let _split-prefix(h) = {
  let m = h.match(regex("^((?:pub(?:\\s*\\([^)]*\\))?\\s+)?)"))
  (prefix: m.captures.at(0), rest: h.slice(m.end))
}

/// Classify an item header. Returns a dictionary with at least `kind`:
/// struct | enum | trait | impl | mod | fn | const ; or `none` when the item is
/// irrelevant for the diagram (use, type alias, macro, free text...).
#let _classify(raw-header) = {
  let lay = _extract-layout(raw-header)
  let h = lay.header
  let sp = _split-prefix(h)
  let prefix = sp.prefix
  let rest = sp.rest

  // Function / method (before const: `const fn`)
  let f = _parse-fn(h)
  if f != none and h.match(regex("^(?:pub(?:\\s*\\([^)]*\\))?\\s+)?(?:(?:default|const|async|unsafe|extern(?:\\s+\"[^\"]*\")?)\\s+)*fn\\b")) != none {
    return (kind: "fn", fn: f)
  }

  // struct / enum / trait share the "Name<Generics> rest" shape
  let tm = rest.match(regex("^(?:(unsafe|auto)\\s+)*(struct|enum|trait)\\s+([A-Za-z_]\\w*)"))
  if tm != none {
    let keyword = tm.captures.at(1)
    let name = tm.captures.at(2)
    let tail = rest.slice(tm.end).trim()
    let generics = none
    if tail.starts-with("<") {
      let g = _take-group(tail, "<", ">")
      if g != none {
        generics = g.inner
        tail = g.rest.trim()
      }
    }
    // Drop `where` clause
    let where-m = tail.match(regex("\\bwhere\\b"))
    let tail-nowhere = if where-m != none { tail.slice(0, where-m.start).trim() } else { tail }

    let tuple = none
    if keyword == "struct" and tail-nowhere.starts-with("(") {
      let g = _take-group(tail-nowhere, "(", ")")
      if g != none { tuple = g.inner }
    }
    let supers = ()
    if keyword == "trait" and tail-nowhere.starts-with(":") {
      supers = _split-commas(tail-nowhere.slice(1).replace("+", ","))
    }
    return (
      kind: keyword,
      name: name,
      generics: generics,
      tuple: tuple,
      supers: supers,
      level: lay.level,
      order: lay.order,
    )
  }

  // impl blocks
  let im = rest.match(regex("^(?:unsafe\\s+)?impl\\b\\s*(.*)$"))
  if im == none { im = h.match(regex("^(?:unsafe\\s+)?impl\\b\\s*(.*)$")) }
  if im != none {
    let tail = im.captures.at(0).trim()
    let generics = none
    if tail.starts-with("<") {
      let g = _take-group(tail, "<", ">")
      if g != none {
        generics = g.inner
        tail = g.rest.trim()
      }
    }
    let where-m = tail.match(regex("\\bwhere\\b"))
    if where-m != none { tail = tail.slice(0, where-m.start).trim() }

    let pieces = tail.split(regex("\\sfor\\s"))
    let trait-name = none
    let type-text = tail
    if pieces.len() >= 2 {
      trait-name = pieces.at(0).trim()
      type-text = pieces.slice(1).join(" for ").trim()
      if trait-name.starts-with("!") { return none } // negative impl
    }
    return (
      kind: "impl",
      generics: generics,
      trait-name: if trait-name != none { _base-name(trait-name) } else { none },
      type-name: _base-name(type-text),
    )
  }

  // mod name { ... }
  let mm = rest.match(regex("^mod\\s+([A-Za-z_]\\w*)\\s*$"))
  if mm != none { return (kind: "mod", name: mm.captures.at(0)) }

  // const / static items (associated constants)
  let cm = rest.match(regex("^(?:(?:const|static)\\s+)(?:mut\\s+)?([A-Za-z_]\\w*)\\s*:\\s*([^=]+)"))
  if cm != none {
    return (
      kind: "const",
      name: cm.captures.at(0),
      type: _ws(cm.captures.at(1)),
      visibility: _visibility(prefix),
    )
  }

  none
}

/// Recursively inline the contents of `mod name { ... }` blocks.
#let _flatten(items) = {
  let out = ()
  for it in items {
    let info = _classify(it.header)
    if info != none and info.kind == "mod" and it.body != none {
      out += _flatten(_scan-items(it.body))
    } else {
      out.push((header: it.header, body: it.body, info: info))
    }
  }
  out
}

/// Fields of a struct body or a tuple-struct parameter list.
/// Returns an array of `(name, type, visibility)`.
#let _parse-fields(text, tuple: false) = {
  let fields = ()
  for (idx, part) in _split-commas(text).enumerate() {
    let p = _ws(_strip-attrs(part))
    if p == "" { continue }
    let sp = _split-prefix(p)
    let vis = _visibility(sp.prefix)
    if tuple {
      fields.push((name: str(idx), type: sp.rest.trim(), visibility: vis))
    } else {
      let m = sp.rest.match(regex("^(?:r#)?([A-Za-z_]\\w*)\\s*:\\s*(.+)$"))
      if m != none {
        fields.push((name: m.captures.at(0), type: m.captures.at(1).trim(), visibility: vis))
      }
    }
  }
  fields
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

#let parse(source) = {
  let items = _flatten(_scan-items(strip-comments(source)))

  let order       = ()      // class names in declaration order
  let classes     = (:)     // name → class dict (members filled at the end)
  let members     = (:)     // name → array of members
  let gparams     = (:)     // name → generic parameter names
  let field-rels  = (:)     // name → (target → (label, type))
  let dep-rels    = (:)     // name → (target → label)
  let relations   = ()      // inheritance / implementation
  let impls       = ()

  // -------------------------------------------------------------------------
  // Pass 1 — struct / enum / trait declarations
  // -------------------------------------------------------------------------
  for it in items {
    let info = it.info
    if info == none { continue }

    if info.kind == "impl" {
      impls.push((info: info, body: it.body))
      continue
    }
    if info.kind not in ("struct", "enum", "trait") { continue }

    let name = info.name
    let cls-type = if info.kind == "enum" { "enum" } else if info.kind == "trait" { "interface" } else { "class" }
    let generics = if info.generics != none and info.generics != "" { _ws(info.generics) } else { none }
    let ignore = _generic-names(info.generics)

    let cls = ir.uml-class(name: name, type: cls-type, generics: generics, level: info.level, order: info.order)
    let mem = ()
    let frels = (:)
    let drels = (:)

    if info.kind == "struct" {
      let fields = ()
      if info.tuple != none {
        fields = _parse-fields(info.tuple, tuple: true)
      } else if it.body != none {
        fields = _parse-fields(it.body)
      }
      for f in fields {
        mem.push(ir.uml-member(
          name: f.name,
          return-type: f.type,
          visibility: f.visibility,
          kind: "field",
        ))
        for target in _type-refs(f.type, ignore) {
          if target != name and target not in frels {
            frels.insert(target, (
              label: f.name,
              type: if _is-shared(f.type) { "aggregation" } else { "composition" },
            ))
          }
        }
      }
    } else if info.kind == "enum" {
      if it.body != none {
        for part in _split-commas(it.body) {
          let p = _ws(_strip-attrs(part))
          let vm = p.match(regex("^([A-Za-z_]\\w*)\\s*(.*)$"))
          if vm == none { continue }
          let vname = vm.captures.at(0)
          let payload = vm.captures.at(1)
          mem.push(ir.uml-member(
            name: vname,
            return-type: none,
            visibility: "public",
            kind: "field",
          ))
          // Payload types: `V(Foo, Bar)` or `V { a: Foo }`
          let payload-types = ()
          if payload.starts-with("(") {
            let g = _take-group(payload, "(", ")")
            if g != none { payload-types = _split-commas(g.inner) }
          } else if payload.starts-with("{") {
            let g = _take-group(payload, "{", "}")
            if g != none {
              payload-types = _parse-fields(g.inner).map(f => f.type)
            }
          }
          for pt in payload-types {
            for target in _type-refs(pt, ignore) {
              if target != name and target not in frels {
                frels.insert(target, (
                  label: vname,
                  type: if _is-shared(pt) { "aggregation" } else { "composition" },
                ))
              }
            }
          }
        }
      }
    } else if info.kind == "trait" {
      for sup in info.supers {
        let sname = _base-name(sup)
        if sname != "" and sname.match(regex("^[A-Z]")) != none and sname not in _std-types {
          relations.push(ir.uml-relation(from: name, to: sname, type: "inheritance"))
        }
      }
      if it.body != none {
        for sub in _scan-items(it.body) {
          let sc = _classify(sub.header)
          if sc == none { continue }
          if sc.kind == "fn" {
            let f = sc.fn
            let all-ignore = ignore + _generic-names(f.generics)
            mem.push(ir.uml-member(
              name: f.name,
              return-type: f.ret,
              visibility: "public",
              modifiers: if sub.body == none { ("abstract",) } else if not f.has-self { ("static",) } else { () },
              kind: "method",
              params: if f.params.len() > 0 { f.params.join(", ") } else { none },
            ))
            for p in f.params {
              let pm = p.match(regex("^[^:]+:\\s*(.+)$"))
              if pm == none { continue }
              for target in _type-refs(pm.captures.at(0), all-ignore) {
                if target != name and target not in drels { drels.insert(target, f.name) }
              }
            }
          } else if sc.kind == "const" {
            mem.push(ir.uml-member(
              name: sc.name,
              return-type: sc.type,
              visibility: "public",
              modifiers: ("static",),
              kind: "field",
            ))
          }
        }
      }
    }

    // A re-declared type (same name in two files) merges into the first one
    if name not in classes {
      order.push(name)
      classes.insert(name, cls)
      members.insert(name, mem)
      gparams.insert(name, ignore)
      field-rels.insert(name, frels)
      dep-rels.insert(name, drels)
    }
  }

  // -------------------------------------------------------------------------
  // Pass 2 — impl blocks (inherent and trait impls)
  // -------------------------------------------------------------------------
  let known-traits = order.filter(n => classes.at(n).type == "interface")

  for im in impls {
    let info = im.info
    let tname = info.type-name
    if tname not in classes { continue }

    let trait-name = info.trait-name
    let local-trait = trait-name != none and trait-name in known-traits

    if trait-name != none {
      if local-trait {
        let dup = relations.any(r => r.from == tname and r.to == trait-name and r.type == "implementation")
        if not dup {
          relations.push(ir.uml-relation(from: tname, to: trait-name, type: "implementation"))
        }
      } else {
        // std / external trait (Display, From, Default...): no relation and
        // no methods, otherwise every `fmt`/`from` would pollute the diagram.
        continue
      }
    }

    if im.body == none { continue }
    let ignore = gparams.at(tname) + _generic-names(info.generics)

    for sub in _scan-items(im.body) {
      let sc = _classify(sub.header)
      if sc == none { continue }

      if sc.kind == "fn" {
        let f = sc.fn
        let all-ignore = ignore + _generic-names(f.generics)
        let mods = if not f.has-self { ("static",) } else { () }
        let mem = members.at(tname)
        mem.push(ir.uml-member(
          name: f.name,
          return-type: f.ret,
          visibility: if trait-name != none { "public" } else { f.visibility },
          modifiers: mods,
          kind: "method",
          params: if f.params.len() > 0 { f.params.join(", ") } else { none },
        ))
        members.insert(tname, mem)

        let drels = dep-rels.at(tname)
        for p in f.params {
          let pm = p.match(regex("^[^:]+:\\s*(.+)$"))
          if pm == none { continue }
          for target in _type-refs(pm.captures.at(0), all-ignore) {
            if target != tname and target not in drels { drels.insert(target, f.name) }
          }
        }
        dep-rels.insert(tname, drels)
      } else if sc.kind == "const" {
        let mem = members.at(tname)
        mem.push(ir.uml-member(
          name: sc.name,
          return-type: sc.type,
          visibility: sc.visibility,
          modifiers: ("static",),
          kind: "field",
        ))
        members.insert(tname, mem)
      }
    }
  }

  // -------------------------------------------------------------------------
  // Assemble IR — only relations between types present in the source
  // -------------------------------------------------------------------------
  let out-classes = ()
  let out-relations = ()

  for name in order {
    let cls = classes.at(name)
    cls.insert("members", members.at(name))
    out-classes.push(cls)

    for (target, rel) in field-rels.at(name) {
      if target in classes {
        out-relations.push(ir.uml-relation(from: name, to: target, type: rel.type, label: rel.label))
      }
    }
    for (target, label) in dep-rels.at(name) {
      if target in classes and target not in field-rels.at(name) {
        out-relations.push(ir.uml-relation(from: name, to: target, type: "dependency", label: label))
      }
    }
  }

  for r in relations {
    if r.to in classes and r.from in classes { out-relations.push(r) }
  }

  ir.uml-diagram(classes: out-classes, relations: out-relations, packages: ())
}
