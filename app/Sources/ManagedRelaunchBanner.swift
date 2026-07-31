// Shared managed-session relaunch progress/error banner.
// MIT License.

import SwiftUI

enum ManagedRelaunchPhase: Equatable {
    case requesting
    case quitting
    case launched
    case complete
    case rejected
    case failed
    case timedOut

    var isTerminal: Bool {
        switch self {
        case .complete, .rejected, .failed, .timedOut: return true
        case .requesting, .quitting, .launched: return false
        }
    }
}

struct ManagedRelaunchStatus: Equatable {
    var sessionID: String
    var sessionTitle: String
    var phase: ManagedRelaunchPhase
    var detail: String
}

struct ManagedRelaunchBanner: View {
    let status: ManagedRelaunchStatus
    var compact = false
    var onDismiss: () -> Void

    private var headline: String {
        switch status.phase {
        case .requesting: return "Requesting managed relaunch"
        case .quitting:   return "Stopping current session"
        case .launched:   return "Managed session launched"
        case .complete:   return "Managed session ready"
        case .rejected:   return "Managed relaunch rejected"
        case .failed:     return "Managed relaunch failed"
        case .timedOut:   return "Managed relaunch timed out"
        }
    }

    private var icon: String {
        switch status.phase {
        case .requesting, .quitting: return "arrow.triangle.2.circlepath"
        case .launched: return "terminal"
        case .complete: return "checkmark.circle.fill"
        case .rejected, .failed: return "exclamationmark.triangle.fill"
        case .timedOut: return "clock.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch status.phase {
        case .complete: return .green
        case .rejected, .failed, .timedOut: return .red
        case .requesting, .quitting, .launched: return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 7 : 9) {
            Image(systemName: icon)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(status.sessionTitle) · \(status.detail)")
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
            }
            Spacer(minLength: 2)
            if status.phase.isTerminal {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 7 : 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }
}
