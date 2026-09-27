import SwiftUI

/// One provider on the Usage tab: its long window (weekly, a month, a billing cycle) as a ring
/// with the even-pace notch, and its 5-hour session as a bar with the pace tick. Each says when
/// it resets, or when it runs out if that comes first.
struct UsageTileView: View {
    var reading: MobileStore.Reading

    private var provider: RelayProvider { reading.provider }
    private var isStale: Bool { !provider.isLive }

    private func pace(_ window: RelayWindow) -> Pace? {
        UsageRanking.pace(for: window, isStale: isStale, history: reading.history[window.id])
    }

    var body: some View {
        let tile = UsageTiles.tile(for: provider)
        let isClose = !isStale && [tile.ring, tile.bar].compactMap { $0 }.contains { !$0.isAwaitingReading() && UsageTiles.isClose($0, pace: pace($0)) }
        VStack(alignment: .leading, spacing: 10) {
            header(isClose: isClose)
            if let ring = tile.ring {
                ringRow(ring)
            } else if let balance = tile.balance {
                balanceBlock(balance)
            }
            if let bar = tile.bar {
                barBlock(bar)
            } else if let detail = detail(tile) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let warning = UsageRanking.limitWarning(for: provider) {
                Text(warning).font(.caption.weight(.semibold)).foregroundStyle(TokenroomTokens.usageCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isStale {
                Text(provider.message ?? "Last reading \(RelativeTime.ago(provider.fetchedAt)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay {
            if isClose {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TokenroomTokens.usageTight, lineWidth: 1.5)
            }
        }
        .opacity(isStale ? 0.7 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func header(isClose: Bool) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: provider, size: 24)
            Text(provider.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isClose {
                Image(systemName: "bell.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TokenroomTokens.tight)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(TokenroomTokens.tight.opacity(0.15)))
                    .accessibilityLabel("Close to a limit")
            }
        }
    }

    private func ringRow(_ ring: RelayWindow) -> some View {
        HStack(spacing: 10) {
            UsageRing(used: ring.used, isStale: isStale || ring.isAwaitingReading(), label: ReadingText.headline(ring), lineWidth: 6, paceMark: pace(ring)?.elapsedFraction)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(ring.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                WindowStatus(window: ring, pace: pace(ring), isStale: isStale)
            }
        }
    }

    private func barBlock(_ bar: RelayWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(ReadingText.headline(bar))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(TokenroomTokens.ink(remaining: 100 - bar.used, isStale: isStale))
            }
            MeterTrack(usedPercent: bar.used, remaining: 100 - bar.used, isStale: isStale || bar.isAwaitingReading(), paceMark: pace(bar)?.elapsedFraction, height: 6, solid: true)
            WindowStatus(window: bar, pace: pace(bar), isStale: isStale)
        }
    }

    private func balanceBlock(_ balance: RelayWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ReadingText.headline(balance))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let forecast = Forecast.text(for: balance, history: reading.history[balance.id], checkedAt: provider.checkedAt ?? provider.fetchedAt) {
                Text(forecast)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Under a ring with no bar: "249 of 300 requests", "$312.50 of $1,000", else the plan.
    private func detail(_ tile: UsageTile) -> String? {
        guard tile.balance == nil else { return nil }
        if let amount = tile.ring?.amount, let detail = ReadingText.amountDetail(amount) {
            return detail
        }
        return provider.plan
    }
}

/// When a window resets, or when it runs out if that comes first.
struct WindowStatus: View {
    var window: RelayWindow
    var pace: Pace?
    var isStale: Bool

    var body: some View {
        if !isStale, let pace, pace.verdict == .limitReached {
            Text(pace.caption())
                .font(.caption.weight(.semibold))
                .foregroundStyle(PaceStyle.color(pace.severity))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if !isStale, let pace, pace.verdict == .ahead, let runsOut = pace.runsOutAt {
            Text("Runs out \(Pace.shortMoment(runsOut, now: .now, timeZone: .current))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PaceStyle.color(pace.severity))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let reset = ReadingText.reset(window) {
            Text(reset)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The top of the Usage tab: every window at 80% or more, or running ahead toward a run-out
/// before its reset, most urgent first. Follow starts the Live Activity for the first.
struct CloseToLimitCard: View {
    var windows: [CloseWindow]
    var open: (String) -> Void
    @State private var followError: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                Text("Close to a limit")
                Text("\(windows.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TokenroomTokens.tight.opacity(0.15)))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TokenroomTokens.accentText)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(windows.prefix(4).enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider()
                        .padding(.leading, 54)
                }
                row(item, isFirst: index == 0)
            }
            if let followError {
                Text(followError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func row(_ item: CloseWindow, isFirst: Bool) -> some View {
        let window = item.window
        let followable = isFirst && LiveActivities.candidate(in: item.provider, preferring: window.id)?.id == window.id
        return HStack(spacing: 12) {
            Button {
                open(item.provider.id)
            } label: {
                HStack(spacing: 12) {
                    ProviderMark(provider: item.provider, size: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // At the accessibility sizes the limit goes under the name, so neither is cut short.
                            let names = typeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                            names {
                                Text(item.provider.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                                Text(window.displayTitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                            }
                            Spacer(minLength: 4)
                            Text(ReadingText.headline(window))
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(TokenroomTokens.ink(remaining: 100 - window.used, isStale: false))
                        }
                        MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: false, paceMark: item.pace?.elapsedFraction, height: 5, solid: true)
                        caption(item)
                            .font(.caption)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every window and the last 7 days")
            if followable {
                FollowButton(provider: item.provider, preferring: window.id, isCompact: true) { followError = $0 }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "Runs out 10:18 AM · 35 min before it resets", "Limit reached · resets in 2h 10m",
    /// "Past 80% · resets Oct 1".
    private func caption(_ item: CloseWindow) -> Text {
        if let pace = item.pace, pace.verdict == .limitReached {
            return Text(pace.caption())
                .fontWeight(.semibold)
                .foregroundStyle(PaceStyle.color(pace.severity))
        }
        if let pace = item.pace, pace.verdict == .ahead, let runsOut = pace.runsOutAt {
            let moment = Text("Runs out \(Pace.shortMoment(runsOut, now: .now, timeZone: .current))")
                .fontWeight(.semibold)
                .foregroundStyle(PaceStyle.color(pace.severity))
            return Text("\(moment) · \(UsageTiles.lead(runsOut: runsOut, resetsAt: pace.resetsAt))").foregroundStyle(.secondary)
        }
        let level = AlertPreferences.supportedThresholds.filter { Double($0) <= item.window.used }.max() ?? Int(UsageTiles.closeUse)
        let reset = ReadingText.reset(item.window).map { " · \($0)" } ?? ""
        return Text("Past \(level)%\(reset)").foregroundStyle(.secondary)
    }
}
