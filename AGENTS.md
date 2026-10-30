# Project conventions

## Commit messages

- Every commit message must use the exact format `-%message;%`, replacing only `message` with the description of the change.
- Example: `-%Add vacancy filtering;%`.

## Swift file headers

- Every authored Swift file (`**/*.swift`) must begin with the standard Xcode file header: filename, project or package name, and `Created by <author> on <date>.`.
- Use `Andrii Bryzhnychenko` for new project files and the actual creation date in the existing Xcode date style (`M/D/YY`). Preserve existing authorship and creation dates; never invent or overwrite them.
- Preserve required leading directives, such as `// swift-tools-version:` in `Package.swift`, and place the header immediately after them.
- These required headers are an explicit exception to the general rule against source comments. Other comments still require approval.

Example for a new file:

```swift
//
//  Example.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/30/26.
//
```
