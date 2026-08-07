export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue }

export interface Bootstrap {
  apiVersion: 'v1'
  profile: string
  csrfToken: string
  revision: number
  capabilities: string[]
  server: WebServerSettings
}

export interface Instance {
  id: string
  name: string
  workflowId: string
  source: string
  sourceKind: 'directory' | 'package' | 'missing'
  status: 'running' | 'starting' | 'reloading' | 'stopping' | 'stopped' | 'failed' | 'needsSource'
  statusDetail: string
  active: boolean
  enabledAtLaunch: boolean
  workingDirectory: string | null
  environmentFilePath: string | null
  environmentVariables: MaskedEnvironmentVariable[]
  requiredEnvironment: RequiredEnvironmentVariable[]
  workflowVariables: Record<string, JSONValue>
  nodePatchCount: number
  nodePatches: Record<string, NodePatch>
  eventSources: Array<{ id: string; kind: string }>
}

export interface NodePatch {
  executionBackend: string | null
  model: string | null
  effort: string | null
}

export interface MaskedEnvironmentVariable {
  name: string
  isSet: boolean
  masked: string
}

export interface RequiredEnvironmentVariable {
  name: string
  description: string | null
  required: boolean
  secret: boolean
  source: 'workflow' | 'addon' | 'agent'
  present: boolean
}

export interface InstancesResponse {
  profile: string
  revision: number
  items: Instance[]
}

export interface InstanceResponse {
  profile: string
  revision: number
  item: Instance
}

export interface WorkflowSources {
  profile: string
  revision: number
  directories: string[]
  projectDirectories: string[]
  repositories: Array<{ id: string; source: string }>
  discovered: Array<{ id: string; name: string; workflowId: string; scope: string; sourceKind: 'directory' | 'package' }>
}

export interface AssistantSettings {
  profile: string
  revision: number
  assistance: string
  vendor: string
  model: string
}

export interface NoteS3Profile {
  name: string
  endpoint: string
  region: string
  bucket: string
  accessKeyIdEnv: string
  secretAccessKeyEnv: string
  sessionTokenEnv: string | null
  keyPrefix: string
}

export interface NoteSettings {
  profile: string
  revision: number
  noteRoot?: string
  exposesNoteAPI: boolean
  s3ProfileCount: number
  s3Profiles?: NoteS3Profile[]
}

export interface NoteAPIClientInfo {
  clientId: string
  displayName: string
  createdAt: string
  lastSeenAt: string | null
}

export interface NoteClientsResponse {
  profile: string
  revision: number
  items: NoteAPIClientInfo[]
}

export interface NoteClientRegistration {
  profile: string
  revision: number
  code: string
  registrationURL: string
  qrText: string
  expiresAt: string
}

export interface AppearanceSettings {
  profile: string
  revision: number
  colorScheme: string
  options: string[]
}

export interface WebServerSettings {
  revision: number
  isEnabled: boolean
  configuredPort: number
  boundPort: number | null
  restartRequired: boolean
  state: string
}

export interface ExecutionsResponse {
  revision: number
  instanceId: string
  items: Execution[]
  diagnostics: string[]
  truncated: boolean
}

export interface Execution {
  sessionId: string
  workflowId: string
  status: string
  currentStepId: string | null
  activeStepIds: string[]
  updatedAt: string
}

export interface RunDetailResponse {
  revision: number
  instanceId: string
  instanceIdTruncated: boolean
  session: {
    sessionId: string
    sessionIdTruncated: boolean
    workflowId: string
    workflowIdTruncated: boolean
    status: string
    currentStepId: string | null
    currentStepIdTruncated: boolean
    updatedAt: string
  }
  steps: RunDetailStep[]
  stepsTotalCount: number
  stepsTruncated: boolean
  logs: RunDetailLog[]
  logsTotalCount: number
  logsTruncated: boolean
  diagnostics: ProjectedSummary[]
  diagnosticsTotalCount: number
  diagnosticsTruncated: boolean
  gates: RunDetailGate[]
  gatesTotalCount: number
  gatesTruncated: boolean
  recovery: {
    entryMode: string
    parentSessionId: string | null
    parentSessionIdTruncated: boolean
    childSessionIds: ProjectedIdentifier[]
    childSessionIdsTotalCount: number
    childSessionIdsTruncated: boolean
    reason: string | null
    reasonTruncated: boolean
  } | null
  truncated: boolean
}

export interface ProjectedSummary {
  summary: string
  truncated: boolean
}

export interface ProjectedIdentifier {
  value: string
  truncated: boolean
}

export interface RunDetailLog {
  communicationId: string
  communicationIdTruncated: boolean
  direction: string
  fromStepId: string | null
  fromStepIdTruncated: boolean
  toStepId: string | null
  toStepIdTruncated: boolean
  sourceStepExecutionId: string | null
  sourceStepExecutionIdTruncated: boolean
  status: string
  deliveryKind: string | null
  createdOrder: number | null
  createdAt: string | null
}

export interface RunDetailStep {
  executionId: string
  executionIdTruncated: boolean
  stepId: string
  stepIdTruncated: boolean
  nodeId: string
  nodeIdTruncated: boolean
  attempt: number
  status: string
  backend: string | null
  startedAt: string
  endedAt: string | null
  durationMs: number | null
  failureReason: string | null
  failureReasonTruncated: boolean
  events: Array<{
    sequence: number
    at: string
    eventType: string
    eventTypeTruncated: boolean
    channel: string | null
    toolName: string | null
    toolNameTruncated: boolean
  }>
  eventTotalCount: number
  eventsTruncated: boolean
}

export interface RunDetailGate {
  gateId: string
  gateIdTruncated: boolean
  stepId: string
  stepIdTruncated: boolean
  decision: string
  blockingFindingCount: number
  findings: Array<{
    id: string
    idTruncated: boolean
    severity: string
    severityTruncated: boolean
    file: string | null
    fileTruncated: boolean
    line: number | null
    summary: string
    summaryTruncated: boolean
    evidenceReferenceCount: number
  }>
  findingsTotalCount: number
  findingsTruncated: boolean
  evidenceRefs: ProjectedIdentifier[]
  evidenceRefsTotalCount: number
  evidenceRefsTruncated: boolean
  diagnostics: ProjectedSummary[]
  diagnosticsTotalCount: number
  diagnosticsTruncated: boolean
}

export interface WorkflowDefinitionResponse {
  revision: number
  sourceId: string
  sourceIdTruncated: boolean
  workflowId: string
  workflowIdTruncated: boolean
  name: string
  nameTruncated: boolean
  scope: string
  sourceKind: 'directory' | 'package'
  definitionRevision: string
  definition: {
    description: string
    descriptionTruncated: boolean
    entryStepId: string
    entryStepIdTruncated: boolean
    managerStepId: string | null
    managerStepIdTruncated: boolean
    steps: Array<{
      id: string
      idTruncated: boolean
      nodeId: string
      nodeIdTruncated: boolean
      role: string | null
      transitions: Array<{
        toStepId: string
        toStepIdTruncated: boolean
        label: string | null
        labelTruncated: boolean
      }>
      transitionsTotalCount: number
      transitionsTruncated: boolean
    }>
    stepsTotalCount: number
    stepsTruncated: boolean
    nodes: Array<{
      id: string
      idTruncated: boolean
      kind: string | null
      role: string | null
    }>
    nodesTotalCount: number
    nodesTruncated: boolean
    transitionsTotalCount: number
    transitionsTruncated: boolean
  }
  diagnostics: ProjectedSummary[]
  diagnosticsTotalCount: number
  diagnosticsTruncated: boolean
  truncated: boolean
}

export interface APIErrorPayload {
  error: { code: string; message: string }
  revision: number
}
