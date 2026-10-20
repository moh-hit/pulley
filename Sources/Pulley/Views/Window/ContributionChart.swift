import SwiftUI
import AppKit

/// GitHub-style contribution heatmap for Home's side column: the last few
/// months of daily activity as a week-by-week grid, with the year's total and
/// the current streak. Cell shades follow GitHub's green ramp so it reads as
/// "your GitHub graph" at a glance.
struct ContributionChart: View {
    let calendar: ContributionCalendar

    /// Weeks shown — what fits a side column at a readable cell size.
    private let weekCount = 20
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 24

    private var weeks: [[ContributionCalendar.Day]] { Array(calendar.weeks.suffix(weekCount)) }

    private var recentTotal: Int { weeks.flatMap { $0 }.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Contributions")
                    .font(Theme.display(20))
                Text("\(calendar.total.formatted()) in the last year")
                    .font(Theme.ui(12))
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                let cell = max(6, (geo.size.width - labelWidth - CGFloat(weeks.count - 1) * gap) / CGFloat(weeks.count))
                VStack(alignment: .leading, spacing: 6) {
                    monthLabels(cell: cell)
                    HStack(alignment: .top, spacing: 0) {
                        weekdayLabels(cell: cell)
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                                weekColumn(week, cell: cell)
                            }
                        }
                    }
                }
            }
            .frame(height: gridHeight)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    stat("\(calendar.currentStreak)", "day streak")
                    stat("\(recentTotal.formatted())", "in \(weekCount) weeks")
                    Spacer(minLength: 0)
                }
                legend
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chrome.opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Contributions: \(calendar.total) in the last year, \(calendar.currentStreak) day streak")
    }

    /// Approximate: month row + 7 rows at the cell size a 300pt column yields.
    private var gridHeight: CGFloat { 16 + 6 + 7 * 10 + 6 * gap + 6 }

    // MARK: Grid

    private func weekColumn(_ week: [ContributionCalendar.Day], cell: CGFloat) -> some View {
        VStack(spacing: gap) {
            // The first week may start mid-week; pad so rows line up by weekday.
            if let first = week.first, first.weekday > 0 {
                ForEach(0..<first.weekday, id: \.self) { _ in
                    Color.clear.frame(width: cell, height: cell)
                }
            }
            ForEach(week, id: \.date) { day in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.contribution(calendar.level(for: day.count)))
                    .frame(width: cell, height: cell)
                    .help(tooltip(day))
            }
        }
    }

    private func weekdayLabels(cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text([1, 3, 5].contains(row) ? ["", "Mon", "", "Wed", "", "Fri", ""][row] : "")
                    .font(Theme.ui(10))
                    .foregroundColor(.secondary)
                    .frame(width: labelWidth, height: cell, alignment: .leading)
            }
        }
    }

    private func monthLabels(cell: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 10)
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    Text(monthLabel(week: week, index: index))
                        .font(Theme.ui(10))
                        .foregroundColor(.secondary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
        }
        .frame(height: 12)
    }

    /// Month name over the first week that contains the 1st–7th of a month.
    private func monthLabel(week: [ContributionCalendar.Day], index: Int) -> String {
        guard let day = week.first(where: { dayOfMonth($0.date) <= 7 }), dayOfMonth(day.date) <= 7,
              index == 0 || dayOfMonth(weeks[index - 1].last?.date ?? day.date) > 7
        else { return "" }
        return Self.monthFormatter.string(from: day.date)
    }

    private func dayOfMonth(_ date: Date) -> Int {
        Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).day ?? 1
    }

    // MARK: Pieces

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(Theme.display(20)).fixedSize()
            Text(label).font(Theme.ui(11)).foregroundColor(.secondary).fixedSize()
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less").font(Theme.ui(10)).foregroundColor(.secondary).fixedSize()
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.contribution(level))
                    .frame(width: 9, height: 9)
            }
            Text("More").font(Theme.ui(10)).foregroundColor(.secondary).fixedSize()
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func tooltip(_ day: ContributionCalendar.Day) -> String {
        let when = Self.dayFormatter.string(from: day.date)
        switch day.count {
        case 0:  return "No contributions on \(when)"
        case 1:  return "1 contribution on \(when)"
        default: return "\(day.count) contributions on \(when)"
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
}
