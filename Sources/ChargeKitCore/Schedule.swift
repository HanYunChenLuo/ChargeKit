import Foundation

// MARK: - Scheduled tasks (S7)
//
// industry-standard task scheduling (common charge-limiter semantics).
// — Task Actions, Repeat Settings, "Automatically Catch Up on Missed Tasks"):
//
// Actions (7): Top Up, Start Calibration Mode, Set Charge Limit, Discharge
// to, Pause Charging, Enable Low Power Mode, Disable Low Power Mode.
// Repeats (7): Daily, Weekdays, Weekly, Biweekly, Monthly, Yearly,
// Don't Repeat. Monthly day 31 only runs in months that have 31 days
// (wording) — short months simply skip, no roll-over.
//
// Catch-up divergence (deliberate): ships "run missed tasks at the
// next opportunity" as a toggle and warns that it should only be enabled
// on Macs used almost daily, to prevent accumulated-task buildup. ChargeKit
// bounds catch-up to the same calendar day instead: an occurrence missed
// while the Mac slept fires on the first tick after wake, occurrences from
// previous days are skipped. Buildup is impossible, so no toggle is needed.

/// The seven schedulable actions (Task Actions).
public enum ScheduleAction: Equatable, Codable {
 /// Set the charge limit to the value; a limit above the current battery
 /// percentage starts charging.
    case setLimit(Int)
 /// Set the limit to the value AND start a discharge toward it (a value
 /// above the current battery charges toward it instead).
    case dischargeTo(Int)
 /// Set the limit to the current battery percentage — charging and
 /// discharging stop.
    case pauseCharging
 /// Charge to (near) 100% once.
    case topUp
 /// Run the calibration cycle.
    case startCalibration
 /// Toggle macOS Low Power Mode (root daemon; there is no public
 /// setter API — the daemon runs `pmset -a lowpowermode`).
    case setLowPowerMode(Bool)
}

public enum ScheduleRepeat: Equatable, Codable {
 /// Fire once at the next matching occurrence, then auto-disable
 /// (Don't Repeat).
    case never
    case daily
 /// Monday through Friday.
    case weekdays
 /// The given weekdays (1=Mon ... 7=Sun), every week.
    case weekly(Set<Int>)
 /// The given weekdays on alternating weeks, anchored to `anchor`'s ISO
 /// week (every other week on the same day and time).
    case biweekly(weekdays: Set<Int>, anchor: Date)
 /// Day of month (1...31); months without that day simply skip — the
 /// 31st only runs in months that have 31 days, matching .
    case monthly(day: Int)
 /// Fixed calendar date every year; February 29 only runs in leap years.
    case yearly(month: Int, day: Int)
}

public struct ScheduleRule: Equatable, Codable, Identifiable {
    public var id: UUID
    public var enabled: Bool
 /// Local wall-clock fire time.
    public var hour: Int  // 0...23
    public var minute: Int  // 0...59
    public var repeatMode: ScheduleRepeat
    public var action: ScheduleAction
 /// Set at creation. Today's occurrence never fires retroactively for a
 /// rule created after its time — an occurrence counts as "missed" only
 /// if it came due after the rule existed (this is what distinguishes
 /// sleep-missed tasks, which must catch up, from freshly created ones,
 /// which must wait for the next occurrence).
    public var createdAt: Date

    public init(
        id: UUID = UUID(), enabled: Bool = true,
        hour: Int, minute: Int,
        repeatMode: ScheduleRepeat, action: ScheduleAction,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.repeatMode = repeatMode
        self.action = action
        self.createdAt = createdAt
    }
}

/// Reconciles an editor draft with schedule state changes that happened while
/// the sheet was open. In particular, a consumed one-shot rule must stay off
/// when the user only saves an unrelated edit.
public enum ScheduleRuleCommit {
    public static func reconcile(
        draft: ScheduleRule,
        original: ScheduleRule?,
        current: ScheduleRule?,
        enabledWasEdited: Bool,
        now: Date
    ) -> ScheduleRule {
        var committed = draft
        guard let original, let current else {
            committed.createdAt = now
            return committed
        }

        if case .never = original.repeatMode,
           original.enabled,
           !current.enabled,
           !enabledWasEdited {
            committed.enabled = false
        }
        if !current.enabled, committed.enabled, enabledWasEdited,
           case .never = original.repeatMode {
 // Explicitly re-enabling a spent one-shot starts from this save
 // time and cannot trigger a missed occurrence retroactively.
 // Recurring rules keep their created time so same-day catch-up
 // still applies, matching the list-toggle path (`toggling`).
            committed.createdAt = now
        }
        return committed
    }

 /// Direct enable/disable from the rule list. A consumed one-shot being
 /// re-enabled starts a new occurrence: its created time moves to now so
 /// a past time today cannot fire retroactively, and the caller must
 /// clear the rule's firing bookkeeping. Recurring rules keep their
 /// original created time so same-day catch-up still applies.
    public static func toggling(
        _ rule: ScheduleRule,
        enabled: Bool,
        hadFired: Bool,
        now: Date
    ) -> (rule: ScheduleRule, clearsBookkeeping: Bool) {
        var updated = rule
        updated.enabled = enabled
        var clears = false
        if enabled, case .never = rule.repeatMode, hadFired {
            updated.createdAt = now
            clears = true
        }
        return (updated, clears)
    }
}

/// Pure scheduler: decides which rules are due at a given moment and keeps
/// the per-rule firing bookkeeping. The app drives it once per tick and
/// persists `lastFiredDay` so a relaunch does not refire today's tasks.
public struct ScheduleEngine {
 /// rule id -> a UTC-midnight encoding of the local calendar day whose
 /// occurrence last fired. This remains stable when the time zone changes.
    public private(set) var lastFiredDay: [UUID: Date]

    public init(lastFiredDay: [UUID: Date] = [:]) {
        self.lastFiredDay = lastFiredDay
    }

 /// Rules whose occurrence is due at `now`, mutating the bookkeeping.
 /// An occurrence is due when
 /// - today is a fire-day for the rule's repeat mode,
 /// - now >= today's occurrence (same-day catch-up: the Mac may have
 /// slept through the scheduled minute),
 /// - the occurrence is not older than the rule itself, and
 /// - it has not fired yet today.
 /// Don't-Repeat rules are returned with `enabled` set to false.
    public mutating func dueRules(
        _ rules: [ScheduleRule],
        now: Date,
        calendar: Calendar,
        workdayCalendar: WorkdayCalendar = WorkdayCalendar()
    ) -> [ScheduleRule] {
        var due: [ScheduleRule] = []
 // Local-day persistence key (stable across time-zone changes).
        let today = Self.localDayKey(for: now, calendar: calendar)
 // The occurrence moment must be computed from the *local* start of
 // day: localDayKey encodes components at UTC midnight, which in
 // negative-offset zones is the previous local evening.
        let localToday = calendar.startOfDay(for: now)
        for var rule in rules where rule.enabled {
            guard Self.fires(
                    on: now,
                    repeatMode: rule.repeatMode,
                    calendar: calendar,
                    workdayCalendar: workdayCalendar),
                  let occurrence = calendar.date(
                      bySettingHour: rule.hour, minute: rule.minute, second: 0, of: localToday),
                  now >= occurrence,
                  occurrence >= rule.createdAt,
                  lastFiredDay[rule.id] != today
            else { continue }
            lastFiredDay[rule.id] = today
            if case .never = rule.repeatMode { rule.enabled = false }
            due.append(rule)
        }
        return due
    }

 /// Drop bookkeeping for rules that no longer exist.
    public mutating func prune(ids: Set<UUID>) {
        lastFiredDay = lastFiredDay.filter { ids.contains($0.key) }
    }

    public mutating func resetLastFiredDay(for ruleID: UUID) {
        lastFiredDay.removeValue(forKey: ruleID)
    }

 /// Stable identity for a civil day in `calendar`: retain its local
 /// calendar components, but encode them at UTC midnight for persistence.
    public static func localDayKey(for date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: date)
        var stableCalendar = calendar
        stableCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        components.timeZone = stableCalendar.timeZone
        return stableCalendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

 /// Whether the day of `date` is a fire-day for the repeat mode.
 /// "Never" matches every day: the one-shot fires at the next occurrence
 /// of the time (The task runs once, at the set time).
    public static func fires(
        on date: Date,
        repeatMode mode: ScheduleRepeat,
        calendar: Calendar,
        workdayCalendar: WorkdayCalendar = WorkdayCalendar()
    ) -> Bool {
 // Calendar weekday is 1=Sun ... 7=Sat; convert to 1=Mon ... 7=Sun.
        let weekday = ((calendar.component(.weekday, from: date) + 5) % 7) + 1
        switch mode {
        case .never:
            return true
        case .daily:
            return true
        case .weekdays:
            return workdayCalendar.isWorkingDay(date, calendar: calendar)
        case .weekly(let days):
            return days.contains(weekday)
        case .biweekly(let days, let anchor):
            return days.contains(weekday)
                && isAnchorParityWeek(of: date, anchor: anchor, calendar: calendar)
        case .monthly(let day):
            return calendar.component(.day, from: date) == day
        case .yearly(let month, let day):
            let c = calendar.dateComponents([.month, .day], from: date)
            return c.month == month && c.day == day
        }
    }

 /// Alternating-week parity: same ISO-week phase as `anchor` (weeks
 /// between the two week starts divisible by 2).
    static func isAnchorParityWeek(of date: Date, anchor: Date, calendar: Calendar) -> Bool {
        var isoCalendar = Calendar(identifier: .iso8601)
        isoCalendar.timeZone = calendar.timeZone
        isoCalendar.firstWeekday = 2
        isoCalendar.minimumDaysInFirstWeek = 4
        guard let dw = isoCalendar.dateInterval(of: .weekOfYear, for: date)?.start,
              let aw = isoCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start
        else { return false }
        let days = isoCalendar.dateComponents([.day], from: aw, to: dw).day ?? 0
        return (days / 7) % 2 == 0
    }
}
