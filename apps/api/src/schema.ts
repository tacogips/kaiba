import {
  KaibaService,
  type KaibaRepository,
  type NoteListFilter,
  type Provenance,
} from "@kaiba/application";
import { createSchema } from "graphql-yoga";

const typeDefs = /* GraphQL */ `
  enum Provenance {
    human
    ai
    system
  }

  type Health {
    status: String!
    aiRuntime: Boolean!
  }

  type Tag {
    id: ID!
    name: String!
    className: String
    createdAt: String!
  }

  type NoteTag {
    id: ID!
    name: String!
    className: String
    provenance: Provenance!
    createdAt: String!
  }

  type Notebook {
    id: ID!
    title: String!
    readOnly: Boolean!
    createdAt: String!
    updatedAt: String!
  }

  type Note {
    id: ID!
    notebookId: ID!
    title: String!
    bodyMarkdown: String!
    readOnly: Boolean!
    tags: [NoteTag!]!
    linkedNoteIds: [ID!]!
    createdAt: String!
    updatedAt: String!
  }

  type NoteSearchResult {
    note: Note!
    snippet: String!
    rank: Float!
  }

  input NoteFilter {
    notebookId: ID
    tagNames: [String!]
    limit: Int
    offset: Int
  }

  input CreateNoteInput {
    notebookId: ID!
    title: String
    bodyMarkdown: String!
    tags: [String!]
    provenance: Provenance = human
  }

  input UpdateNoteInput {
    id: ID!
    title: String
    bodyMarkdown: String
    readOnly: Boolean
  }

  type Query {
    health: Health!
    note(id: ID!): Note
    notes(filter: NoteFilter): [Note!]!
    notebook(id: ID!): Notebook
    notebooks: [Notebook!]!
    tags: [Tag!]!
    searchNotes(query: String!, filter: NoteFilter): [NoteSearchResult!]!
  }

  type Mutation {
    createNotebook(title: String!): Notebook!
    createNote(input: CreateNoteInput!): Note!
    updateNote(input: UpdateNoteInput!): Note!
    deleteNote(id: ID!): Boolean!
    applyNoteTags(noteId: ID!, names: [String!]!, provenance: Provenance = human): Note!
    removeNoteTag(noteId: ID!, name: String!): Note!
    linkNotes(sourceId: ID!, targetId: ID!): Note!
    unlinkNotes(sourceId: ID!, targetId: ID!): Note!
  }
`;

type Context = { readonly service: KaibaService };
type FilterArguments = { readonly filter?: NoteListFilter | null | undefined };
type CreateNoteArguments = {
  readonly input: {
    readonly notebookId: string;
    readonly title?: string | null | undefined;
    readonly bodyMarkdown: string;
    readonly tags?: readonly string[] | null | undefined;
    readonly provenance?: Provenance | null | undefined;
  };
};
type UpdateNoteArguments = {
  readonly input: {
    readonly id: string;
    readonly title?: string | null | undefined;
    readonly bodyMarkdown?: string | null | undefined;
    readonly readOnly?: boolean | null | undefined;
  };
};

export function createKaibaSchema(repository: KaibaRepository) {
  const service = new KaibaService({ repository });
  return createSchema<Context>({
    typeDefs,
    resolvers: {
      Query: {
        health: () => ({ status: "ok", aiRuntime: false }),
        note: (_root, args: { readonly id: string }) =>
          service.getNote(args.id),
        notes: (_root, args: FilterArguments) =>
          service.listNotes(args.filter ?? {}),
        notebook: (_root, args: { readonly id: string }) =>
          service.getNotebook(args.id),
        notebooks: () => service.listNotebooks(),
        tags: () => service.listTags(),
        searchNotes: (
          _root,
          args: FilterArguments & { readonly query: string },
        ) => service.searchNotes(args.query, args.filter ?? {}),
      },
      Mutation: {
        createNotebook: (_root, args: { readonly title: string }) =>
          service.createNotebook(args.title),
        createNote: (_root, args: CreateNoteArguments) =>
          service.createNote({
            notebookId: args.input.notebookId,
            bodyMarkdown: args.input.bodyMarkdown,
            ...(args.input.title == null ? {} : { title: args.input.title }),
            ...(args.input.tags == null ? {} : { tags: args.input.tags }),
            ...(args.input.provenance == null
              ? {}
              : { provenance: args.input.provenance }),
          }),
        updateNote: (_root, args: UpdateNoteArguments) =>
          service.updateNote({
            id: args.input.id,
            ...(args.input.title == null ? {} : { title: args.input.title }),
            ...(args.input.bodyMarkdown == null
              ? {}
              : { bodyMarkdown: args.input.bodyMarkdown }),
            ...(args.input.readOnly == null
              ? {}
              : { readOnly: args.input.readOnly }),
          }),
        deleteNote: (_root, args: { readonly id: string }) =>
          service.deleteNote(args.id),
        applyNoteTags: (
          _root,
          args: {
            readonly noteId: string;
            readonly names: readonly string[];
            readonly provenance?: Provenance | undefined;
          },
        ) =>
          service.applyNoteTags(
            args.noteId,
            args.names,
            args.provenance ?? "human",
          ),
        removeNoteTag: (
          _root,
          args: { readonly noteId: string; readonly name: string },
        ) => service.removeNoteTag(args.noteId, args.name),
        linkNotes: (
          _root,
          args: { readonly sourceId: string; readonly targetId: string },
        ) => service.linkNotes(args.sourceId, args.targetId),
        unlinkNotes: (
          _root,
          args: { readonly sourceId: string; readonly targetId: string },
        ) => service.unlinkNotes(args.sourceId, args.targetId),
      },
    },
  });
}
