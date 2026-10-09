import Foundation
import Testing
@testable import CodexBarCore

/// Synthetic `/usage` screens shaped like the Claude CLI panel. Amounts, model names, and time zones are fictitious.
enum ClaudeCLIUsageFixtures {
    static let insights = """
      What's contributing to your limits usage?
      Approximate, based on local sessions on this machine - does not include other devices or claude.ai

      Last 24h - these are independent characteristics of your usage, not a breakdown

      90% of your usage was at >150k context
       Longer sessions are more expensive even when cached. /compact mid-task, /clear
       when switching to new tasks.

      57% of your usage came from subagents under "general-purpose"
       If this runs frequently, consider configuring its subagents with a cheaper
       model or tightening their prompts.

      Subagents               % of usage
      general-purpose                57%
    """

    static let creditsBlock = """
      Usage credits
      █████████████████████                              42% used
      $420.00 / $1,000.00 spent · Resets Nov 1 (America/New_York)
    """

    static func screen(quota: String = "", credits: String? = creditsBlock) -> String {
        """
        ❯ /usage

        ──────────────────────────────────────────────────────────────
          Settings  Status   Config   Usage   Stats

          Session

          Total cost:            $0.0000
          Total duration (API):  0s
          Usage:                 0 input, 0 output, 0 cache read, 0 cache write

        \(quota)
        \(self.insights)

          d to day · w to week

        \(credits ?? "")

          Esc to cancel
        """
    }

    static let weeklyQuota = """
      Current week (all models)
      █▌                                                 12% used
      Resets Jul 10 at 2:59am (Europe/Prague)
    """

    static let modelOnlyQuota = """
      Current week (Fable)
      ▌                                                   7% used
      Resets Jul 10 at 2:59am (Europe/Prague)
    """

    static let sessionAndWeeklyQuota = """
      Current session
      ███████▌                                           13% used
      Resets 2:20pm (Asia/Singapore)

      Current week (all models)
      █                                                   2% used
      Resets Oct 3 at 8am (Asia/Singapore)
    """

    static func loadUsage(_ status: ClaudeStatusSnapshot) async throws -> ClaudeUsageSnapshot {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in status }
        return try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                try await fetcher.loadLatestUsage(model: "sonnet")
            }
        }
    }

    /// The shape the PTY capture loop scans: lowercased with all whitespace removed.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }
}
