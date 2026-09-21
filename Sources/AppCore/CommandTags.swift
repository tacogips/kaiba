import Foundation

extension AppCommand {
  /// `tag` carries three shapes: the `promote`/`unpromote` subcommands, the
  /// note-tagging write (`<note-id> --add/--remove`), and the tag entity page
  /// (`<tag-name-or-id>`, `design-docs/specs/note-capture-and-entity-pages.md`
  /// E5/E7). The subcommand is peeked rather than extracted so a tag literally
  /// named `promote` stays reachable through `--tag promote`, and so the
  /// dispatch reads like `runNotebook`'s.
  func runTag(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    switch cursor.remaining.first {
    case "promote":
      _ = cursor.next()
      var subContext = context
      subContext.cursor = cursor
      return try runTagPromote(subContext)
    case "unpromote":
      _ = cursor.next()
      var subContext = context
      subContext.cursor = cursor
      return try runTagUnpromote(subContext)
    default:
      return try runTagAssignOrShow(context)
    }
  }

  /// Without `--add`/`--remove` the positional is a tag, not a note, and the
  /// command renders that tag's entity page. With either option it is the
  /// long-standing note-tagging write, unchanged.
  private func runTagAssignOrShow(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let additions = try cursor.extractOptionValues("--add")
    let removals = try cursor.extractOptionValues("--remove")
    if additions.isEmpty && removals.isEmpty {
      return try runTagShow(context)
    }
    guard let noteId = cursor.nextIdentifier(as: NoteID.self) else {
      throw Error.invalidUsage("tag requires <note-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    var note: Note?
    if !additions.isEmpty {
      note = try service.applyTags(
        noteId: noteId,
        tags: additions.map { NoteTagInput(name: $0) },
        provenance: .human,
        assignedBy: "kaiba-cli"
      )
    }
    for name in removals {
      note = try service.removeTag(noteId: noteId, tagName: name, removedBy: .human)
    }
    let tags = note?.tags ?? []
    let rendered = tags.isEmpty ? "(none)" : tags.map(renderTagLine).joined(separator: " ")
    return "Tags on \(noteId): \(rendered)"
  }

  /// `kaiba tag <name-or-id>` — the tag entity page on the CLI (E5/E7): the
  /// same `tagDetail` payload the pane and GraphQL read, including the
  /// canonical note and the top co-occurring tags.
  private func runTagShow(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    guard let reference = cursor.next() else {
      throw Error.invalidUsage(
        "tag requires <note-id> with --add/--remove, or <tag-name-or-id> to show a tag"
      )
    }
    try cursor.finish()

    let service = try makeService(context)
    let tags = try service.listTags()
    guard let tag = try matchTagReference(reference, in: tags) else {
      throw Error.invalidUsage(unresolvedTagReferenceMessage(reference))
    }
    let detail = try service.tagDetail(tagId: tag.tagId)
    switch output {
    case .json:
      return try renderJSON(tagDetailJSON(detail))
    case .text:
      return renderTagDetail(detail, knownTags: tags)
    }
  }

  /// The `--output json` shape of the entity page. Optional members are
  /// dropped rather than written as null, matching `jsonObject(_ tag:)`.
  private func tagDetailJSON(_ detail: TagDetail) -> JSONObject {
    var object: JSONObject = [
      "tag": .object(jsonObject(detail.tag)),
      "noteCount": .integer(Int64(detail.noteCount)),
      "notebookCount": .integer(Int64(detail.notebookCount)),
      "coOccurringTags": .array(detail.coOccurringTags.map { occurrence in
        .object([
          "tag": .object(jsonObject(occurrence.tag)),
          "noteCount": .integer(Int64(occurrence.noteCount))
        ])
      })
    ]
    // The tag object already carries `classId`; this adds the label, which is
    // what an entity header actually shows.
    object["tagClass"] = detail.tagClass.map { tagClass in
      .object([
        "classId": .id(tagClass.classId),
        "label": .string(tagClass.label),
        "isSystem": .bool(tagClass.isSystem)
      ])
    }
    object["memoNotebookId"] = detail.memoNotebookId.map(JSONValue.id)
    object["canonicalNote"] = detail.canonicalNote.map { .object(jsonObject($0)) }
    return object
  }

  /// `kaiba tag promote --tag <name-or-id> --note <note-id>` (E2/E7).
  private func runTagPromote(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let reference = try cursor.extractOption("--tag")
    let noteId = try cursor.extractIdentifierOption("--note", as: NoteID.self)
    guard let reference, let noteId else {
      throw Error.invalidUsage("tag promote requires --tag <name-or-id> and --note <note-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let tag = try resolveTagReference(reference, in: try service.listTags())
    // Whatever the service refuses here — a missing note, a folder-class or
    // document-kind tag, a note out of reach — is surfaced verbatim. The
    // command layer deliberately re-derives none of those rules.
    let note = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: noteId)
    return "Promoted \(note.noteId) as the canonical note for \(tag.name) (\(tag.tagId))"
  }

  /// `kaiba tag unpromote --tag <name-or-id>` (E2/E7). Clearing an unbound tag
  /// is a no-op success, exactly as the service reports it.
  private func runTagUnpromote(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let reference = try cursor.extractOption("--tag") else {
      throw Error.invalidUsage("tag unpromote requires --tag <name-or-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let tag = try resolveTagReference(reference, in: try service.listTags())
    guard let note = try service.unpromoteTagCanonicalNote(tagId: tag.tagId) else {
      return "\(tag.name) (\(tag.tagId)) had no canonical note"
    }
    return "Cleared the canonical note \(note.noteId) for \(tag.name) (\(tag.tagId))"
  }

  /// Resolves a `<name-or-id>` argument to a tag id. An exact id match wins,
  /// because ids are unique; otherwise the name must identify exactly one tag.
  /// Duplicate names under different parents are legal, so an ambiguous name
  /// is refused with the candidate ids rather than resolved arbitrarily — the
  /// same stance `findTag(name:in:)` takes inside the service.
  private func resolveTagReference(
    _ reference: String,
    in tags: [Tag]
  ) throws -> Tag {
    guard let tag = try matchTagReference(reference, in: tags) else {
      throw Error.invalidUsage("tag not found: \(reference)")
    }
    return tag
  }

  /// The resolution itself, reporting "no such tag" as `nil` so a caller can
  /// word that one case for its own surface. Ambiguity still throws, because
  /// that refusal reads the same wherever the reference came from.
  private func matchTagReference(
    _ reference: String,
    in tags: [Tag]
  ) throws -> Tag? {
    if let byId = tags.first(where: { $0.tagId.rawValue == reference }) {
      return byId
    }
    let byName = tags.filter { $0.name == reference }
    guard let first = byName.first else {
      return nil
    }
    guard byName.count == 1 else {
      let candidates = byName.map(\.tagId.rawValue).joined(separator: ", ")
      throw Error.invalidUsage(
        "tag name is ambiguous: \(reference); pass one of these ids instead: \(candidates)"
      )
    }
    return first
  }

  /// Wording for a positional that resolved to no tag.
  ///
  /// `kaiba tag <note-id>` was the note-tagging write's only shape until the
  /// entity page (E7) took over the bare positional, and forgetting
  /// `--add`/`--remove` used to answer with the option hint. Afterwards the
  /// same slip resolved the note id as a tag name and answered
  /// `tag not found: note-…`, which points the operator nowhere. A reference
  /// carrying the minted note-id prefix gets the old hint back; anything else
  /// is a genuinely unknown tag and says so. The prefix is consulted only
  /// after resolution failed, so a tag actually named `note-…` still resolves
  /// to its own entity page.
  private func unresolvedTagReferenceMessage(_ reference: String) -> String {
    guard reference.hasPrefix("\(NoteID.generatedPrefix)-") else {
      return "tag not found: \(reference)"
    }
    return "tag requires --add <name> or --remove <name>"
  }

  private func renderTagDetail(_ detail: TagDetail, knownTags: [Tag]) -> String {
    var lines = ["Tag \(detail.tag.name) (\(detail.tag.tagId))"]
    var attributes: [String] = []
    if let tagClass = detail.tagClass {
      attributes.append("class=\(tagClass.classId)")
    }
    if let parent = detail.tag.parentTagId {
      let name = knownTags.first { $0.tagId == parent }?.name
      attributes.append("parent=\(name ?? parent.rawValue)")
    }
    if detail.tag.isSystem {
      attributes.append("[system]")
    }
    if !attributes.isEmpty {
      lines.append("  " + attributes.joined(separator: "  "))
    }
    lines.append("  notes=\(detail.noteCount)  notebooks=\(detail.notebookCount)")
    if let canonical = detail.canonicalNote {
      let title = canonical.title ?? "(untitled)"
      lines.append("  canonical note: \(canonical.noteId)  \(title)")
    } else {
      lines.append("  canonical note: (none)")
    }
    if detail.coOccurringTags.isEmpty {
      lines.append("  co-occurring tags: (none)")
    } else {
      let rendered = detail.coOccurringTags
        .map { "#\($0.tag.name) (\($0.noteCount))" }
        .joined(separator: "  ")
      lines.append("  co-occurring tags: \(rendered)")
    }
    return lines.joined(separator: "\n")
  }

  func runTags(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let classFilter = try cursor.extractIdentifierOption("--class", as: TagClassID.self)
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    var tags = try service.listTags()
    if let classFilter {
      tags = tags.filter { $0.classId == classFilter }
    }
    switch output {
    case .json:
      return try renderJSON(tags.map(jsonObject))
    case .text:
      guard !tags.isEmpty else {
        return "No tags."
      }
      let byId = Dictionary(uniqueKeysWithValues: tags.map { ($0.tagId, $0.name) })
      return tags.map { tag in
        var parts = [tag.name]
        if let classId = tag.classId {
          parts.append("class=\(classId)")
        }
        if let parent = tag.parentTagId {
          parts.append("parent=\(byId[parent] ?? parent.rawValue)")
        }
        if tag.isSystem {
          parts.append("[system]")
        }
        return parts.joined(separator: "  ")
      }.joined(separator: "\n")
    }
  }

  func runClasses(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    let classes = try service.listTagClasses()
    switch output {
    case .json:
      return try renderJSON(classes.map { tagClass -> JSONObject in
        var object: JSONObject = [
          "classId": .id(tagClass.classId),
          "label": .string(tagClass.label),
          "isSystem": .bool(tagClass.isSystem),
          "createdAt": .string(tagClass.createdAt)
        ]
        object["description"] = tagClass.description.map(JSONValue.string)
        return object
      })
    case .text:
      return classes.map { tagClass in
        var parts = ["\(tagClass.classId)  \(tagClass.label)"]
        if let description = tagClass.description {
          parts.append("\u{2014} \(description)")
        }
        if tagClass.isSystem {
          parts.append("[system]")
        }
        return parts.joined(separator: "  ")
      }.joined(separator: "\n")
    }
  }

  func runTagDefine(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let classId = try cursor.extractIdentifierOption("--class", as: TagClassID.self)
    let parentName = try cursor.extractOption("--parent")
    guard let name = cursor.next() else {
      throw Error.invalidUsage("tag-define requires <name>")
    }
    try cursor.finish()

    let service = try makeService(context)
    var parentTagId: TagID?
    if let parentName {
      guard let parent = try service.listTags().first(where: { $0.name == parentName }) else {
        throw Error.invalidUsage("parent tag not found: \(parentName)")
      }
      parentTagId = parent.tagId
    }
    let tag = try service.defineTag(name: name, classId: classId, parentTagId: parentTagId)
    var parts = ["Defined tag \(tag.name) (\(tag.tagId))"]
    if let classId = tag.classId {
      parts.append("class=\(classId)")
    }
    if parentName != nil {
      parts.append("parent=\(parentName ?? "")")
    }
    return parts.joined(separator: "  ")
  }

  func runClassDefine(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let label = try cursor.extractOption("--label")
    let description = try cursor.extractOption("--description")
    guard let classId = cursor.nextIdentifier(as: TagClassID.self), let label else {
      throw Error.invalidUsage("class-define requires <class-id> and --label")
    }
    try cursor.finish()

    let service = try makeService(context)
    let tagClass = try service.defineTagClass(
      classId: classId,
      label: label,
      description: description
    )
    return "Defined tag class \(tagClass.classId) (\(tagClass.label))"
  }
}
