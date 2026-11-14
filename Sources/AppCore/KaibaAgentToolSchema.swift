import Foundation

/// JSON Schema declarations for `KaibaAgentToolbox`
/// (`design-docs/specs/user-agent-tools.md`, UA4). Kept apart from the
/// executor so the contract the model sees is reviewable in one place.
enum KaibaAgentToolSchema {
  static let definitions: [AgentToolDefinition] = [
    AgentToolDefinition(
      name: "search_notes",
      description: "Full-text search over the notes the user can see. Returns note ids, titles, "
        + "snippets, tags, and term_coverage (1.0 = every query word matched; lower = partial "
        + "match, weaker evidence). Notes matching every word come first. Run several short, "
        + "focused queries (synonyms, sub-questions, entity or tag names) rather than one long "
        + "query, and read term_coverage before trusting a hit. Set include_linked for "
        + "'related to' questions to also get notes linked to or sharing rare tags with the "
        + "hits (is_linked_neighbor = true). Use get_note to read a full body.",
      inputSchema: object(
        properties: [
          "query": string("Search text. Plain words work best."),
          "notebook_id": string("Restrict the search to one notebook."),
          "tags": array(string("Tag name."), description: "Only notes carrying any of these tags "
            + "(child tags of a named tag count)."),
          "include_linked": boolean("Also return graph neighbours of the hits, ranked after them."),
          "limit": integer("Maximum results, 1-50 (default 10).")
        ],
        required: ["query"]
      )
    ),
    AgentToolDefinition(
      name: "get_note",
      description: "Read one note: full markdown body, tags, comments, and links.",
      inputSchema: object(properties: ["note_id": string("The note id.")], required: ["note_id"])
    ),
    AgentToolDefinition(
      name: "list_notebooks",
      description: "List notebooks the user can see, newest first, with note counts and tags.",
      inputSchema: object(
        properties: [
          "limit": integer("Maximum notebooks, 1-200 (default 50)."),
          "offset": integer("Skip this many notebooks for paging.")
        ],
        required: []
      )
    ),
    AgentToolDefinition(
      name: "get_notebook",
      description: "Read one notebook and a page of its notes (id, number, title, preview).",
      inputSchema: object(
        properties: [
          "notebook_id": string("The notebook id."),
          "limit": integer("Maximum notes, 1-200 (default 100)."),
          "offset": integer("Skip this many notes for paging.")
        ],
        required: ["notebook_id"]
      )
    ),
    AgentToolDefinition(
      name: "create_notebook",
      description: "Create an empty notebook owned by the user.",
      inputSchema: object(properties: ["title": string("Notebook title.")], required: ["title"])
    ),
    AgentToolDefinition(
      name: "create_note",
      description: "Create a note. Give notebook_id to add to an existing notebook, or "
        + "notebook_title to create a new notebook for it; omit both for a standalone note.",
      inputSchema: object(
        properties: [
          "body_markdown": string("The note body in markdown."),
          "notebook_id": string("Existing notebook to add the note to."),
          "notebook_title": string("Title for a new notebook when notebook_id is omitted."),
          "title": string("Optional explicit title; otherwise derived from the body."),
          "tags": tagArray
        ],
        required: ["body_markdown"]
      )
    ),
    AgentToolDefinition(
      name: "update_note_body",
      description: "Replace a note's markdown body. The previous body stays in the undo history.",
      inputSchema: object(
        properties: [
          "note_id": string("The note id."),
          "body_markdown": string("The complete new body.")
        ],
        required: ["note_id", "body_markdown"]
      )
    ),
    AgentToolDefinition(
      name: "add_comment",
      description: "Attach a comment (memo) to a note without changing its body.",
      inputSchema: object(
        properties: [
          "note_id": string("The note id."),
          "body_markdown": string("The comment text.")
        ],
        required: ["note_id", "body_markdown"]
      )
    ),
    AgentToolDefinition(
      name: "apply_note_tags",
      description: "Add tags to a note. Existing tags are kept. Tags are created when unknown.",
      inputSchema: object(
        properties: [
          "note_id": string("The note id."),
          "tags": tagArray
        ],
        required: ["note_id", "tags"]
      )
    ),
    AgentToolDefinition(
      name: "remove_note_tag",
      description: "Remove one tag from a note.",
      inputSchema: object(
        properties: [
          "note_id": string("The note id."),
          "tag": string("The tag name to remove.")
        ],
        required: ["note_id", "tag"]
      )
    ),
    AgentToolDefinition(
      name: "list_tags",
      description: "List every tag with its class and parent.",
      inputSchema: object(properties: [:], required: [])
    ),
    AgentToolDefinition(
      name: "link_notes",
      description: "Record a directed relation between two notes.",
      inputSchema: object(
        properties: [
          "from_note_id": string("Source note id."),
          "to_note_id": string("Target note id."),
          "link_kind": string("Relation kind (default \"related\").")
        ],
        required: ["from_note_id", "to_note_id"]
      )
    ),
    AgentToolDefinition(
      name: "delete_note",
      description: "Delete a note. Reversible with undo_last_action.",
      inputSchema: object(properties: ["note_id": string("The note id.")], required: ["note_id"])
    ),
    AgentToolDefinition(
      name: "undo_last_action",
      description: "Undo the user's most recent undoable action (including the agent's own writes).",
      inputSchema: object(properties: [:], required: [])
    )
  ]

  private static var tagArray: JSONValue {
    .object([
      "type": .string("array"),
      "description": .string("Tag names, or objects {\"name\": ..., \"class_id\": ...}."),
      "items": .object([
        "anyOf": .array([
          .object(["type": .string("string")]),
          .object([
            "type": .string("object"),
            "properties": .object([
              "name": .object(["type": .string("string")]),
              "class_id": .object(["type": .string("string")])
            ]),
            "required": .array([.string("name")])
          ])
        ])
      ])
    ])
  }

  private static func object(properties: JSONObject, required: [String]) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": .bool(false)
    ])
  }

  private static func string(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

  private static func integer(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
  }

  private static func boolean(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
  }

  private static func array(_ items: JSONValue, description: String) -> JSONValue {
    .object(["type": .string("array"), "items": items, "description": .string(description)])
  }
}
