import Foundation

/// Workday policy used by repeating "weekdays" schedule rules.
public enum WorkdayCalendarRegion: String, CaseIterable, Codable, Identifiable {
    case systemWeekend
    case mainlandChina

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemWeekend: return "本地周末"
        case .mainlandChina: return "中国大陆"
        }
    }

    public var detail: String {
        switch self {
        case .systemWeekend:
            return "按系统地区识别周末；不查询公共节假日。"
        case .mainlandChina:
            return "通过 Timor 节假日 API 获取假日与补班；数据不可用时按周一至周五。"
        }
    }

 /// Follow the Mac's region by default, with an explicit choice available
 /// for people whose system region differs from their work calendar.
    public static var defaultRegion: Self {
        Locale.current.region?.identifier == "CN" ? .mainlandChina : .systemWeekend
    }
}

/// Resolves whether a date is a working day for a schedule rule.
public struct WorkdayCalendar {
    public let region: WorkdayCalendarRegion
    private let workingDateKeysByYear: [Int: Set<Int>]

    public init(
        region: WorkdayCalendarRegion = .systemWeekend,
        workingDateKeysByYear: [Int: Set<Int>] = [:]
    ) {
        self.region = region
        self.workingDateKeysByYear = workingDateKeysByYear
    }

    public func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool {
        switch region {
        case .systemWeekend:
            return !calendar.isDateInWeekend(date)
        case .mainlandChina:
            let gregorian = Self.gregorianCalendar(matching: calendar)
            let components = gregorian.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let weekday = components.weekday
            else {
                return false
            }

            let key = year * 10_000 + month * 100 + day
            if let workingDates = workingDateKeysByYear[year] {
                return workingDates.contains(key)
            }

 // When the service has no complete data for a year, retain the
 // normal Mainland China Monday-to-Friday baseline.
            return weekday != 1 && weekday != 7
        }
    }

    private static func gregorianCalendar(matching calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        return result
    }

 /// Gregorian year of `date`'s civil day in `calendar`'s time zone. The
 /// service calendar and the date keys are Gregorian; the host system
 /// calendar may use another identifier (for example Buddhist), so every
 /// workday year computation goes through this.
    public static func gregorianYear(for date: Date, calendar: Calendar) -> Int {
        gregorianCalendar(matching: calendar).component(.year, from: date)
    }
}