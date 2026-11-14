import Foundation

extension AppCommand {
  func runTag(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let additions = try cursor.extractOptionValues("--add")
    let removals = try cursor.extractOptionValues("--remove")
    guard let noteId = cursor.next() else {
      throw Error.invalidUsage("tag requires <note-id>")
    }
    guard !additions.isEmpty || !removals.isEmpty else {
      throw Error.invalidUsage("tag requires --add <name> or --remove <name>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
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

  func runTags(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let classFilter = try cursor.extractOption("--class")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
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
          parts.append("parent=\(byId[parent] ?? parent)")
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

    let service = try makeService(root: context.noteRoot)
    let classes = try service.listTagClasses()
    switch output {
    case .json:
      return try renderJSON(classes.map { tagClass -> [String: Any] in
        var object: [String: Any] = [
          "classId": tagClass.classId,
          "label": tagClass.label,
          "isSystem": tagClass.isSystem,
          "createdAt": tagClass.createdAt
        ]
        object["description"] = tagClass.description
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
    let classId = try cursor.extractOption("--class")
    let parentName = try cursor.extractOption("--parent")
    guard let name = cursor.next() else {
      throw Error.invalidUsage("tag-define requires <name>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    var parentTagId: String?
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
    guard let classId = cursor.next(), let label else {
      throw Error.invalidUsage("class-define requires <class-id> and --label")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let tagClass = try service.defineTagClass(
      classId: classId,
      label: label,
      description: description
    )
    return "Defined tag class \(tagClass.classId) (\(tagClass.label))"
  }
}
