# AGENTS.md

## File IO
use Xcode tools to write to files.

## General Coding Style

### `guard`
Use `guard` for early exits. Prefer the most compact form that stays readable.

**Single condition + immediate exit**  
If the condition is one line and the `else` only exits (`return` / `break` / `continue` / `throw`), prefer a one-liner:

```swift
guard condition else { return }
```

**Multiple bindings / multiline conditions**  
If there are multiple `let` bindings or the condition needs to wrap, format one item per line and keep braces on the same line:

```swift
guard let foo,
      let bar else {
    return
}
```

**When doing any kind of DSP, use Accelerate**.


## File Management

- Prefer small, focused files over “one huge file”.
- Organize code into a clear hierarchy (by feature, screen, or component).
- Extract reusable views / helpers into their own files when they grow beyond a reasonable size or are used in multiple places.

