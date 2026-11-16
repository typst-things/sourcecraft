#import "../src/lib.typ": source-diagram, setup-sourceuml
#set page(paper: "a4", flipped: true)

= Teste Gramática: Rust

#let src = (
  "#[layout(level = 0, order = 0)]",
  read("rust/animal.rs"),
  read("rust/cachorro.rs"),
  read("rust/dono.rs"),
).join("\n\n")

#source-diagram(src, grammar: "rust", max-height: 15cm)

#show: setup-sourceuml
```source-diagram-rust
struct Foo { bar: Bar }
struct Bar { n: i32 }
```
