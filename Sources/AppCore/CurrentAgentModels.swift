import Foundation

/// Vendor model identifiers verified against their official catalogs on 2026-10-25.
/// Runtime availability and credentials remain the provider's authority.
public enum CurrentAgentModels {
  public static func models(for vendor: String) -> [String] {
    switch vendor {
    case "codex", "openai":
      return ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]
    case "claude-code", "anthropic":
      return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    case "gemini":
      return ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.5-flash-lite"]
    default:
      return []
    }
  }

  public static func resolved(_ model: String, vendor: String) -> String {
    let current = models(for: vendor)
    let isVendorModel = model.hasPrefix("gpt-") || model.hasPrefix("claude-") || model.hasPrefix("gemini-")
    if model == "gpt-5.6-luna" { return current.first ?? "gpt-6.1-sol" }
    return isVendorModel && !current.isEmpty && !current.contains(model) ? current[0] : model
  }

  public static let selectableGatewayVendors: Set<String> = ["codex", "claude-code", "openai", "anthropic", "gemini"]
}
