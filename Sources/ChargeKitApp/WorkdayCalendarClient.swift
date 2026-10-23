import Foundation
import ChargeKitCore

/// Fetches and caches one complete year's workday map from Timor Tech.
/// All mutable state is read or written on the main queue.
final class WorkdayCalendarClient {
    private struct CacheRecord: Codable {
        let year: Int
        let typeRecordCount: Int
        let exceptionalDateCount: Int
        let workingDateKeys: [Int]
        let fetchedAt: Date
    }

    private struct APIResponse: Decodable {
        let code: Int
        let holiday: [String: APIHoliday]?
        let type: [String: APIDayType]?
    }

    private struct APIHoliday: Decodable {
        let holiday: Bool
    }

    private struct APIDayType: Decodable {
        let type: Int
    }

    private enum APIError: Error {
        case invalidResponse
        case httpStatus(Int)
        case serviceCode(Int)
        case incompleteYear
        case invalidRecord
        case responseTooLarge
    }

    private static let cacheAge: TimeInterval = 30 * 24 * 60 * 60
    private static let retryDelay: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumResponseBytes = 512 * 1024
    private static let cacheKeyPrefix = "workdayCalendar.timor.v2."
    private static let requestKeyPrefix = "workdayCalendar.timor.v2.lastAttempt."

    private let defaults: UserDefaults
    private(set) var workingDateKeysByYear: [Int: Set<Int>] = [:]
    private var fetchedAtByYear: [Int: Date] = [:]
    private var inFlightYears: Set<Int> = []
    private var requestsByYear: [Int: BoundedWorkdayRequest] = [:]
    private var unavailableYears: Set<Int> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let currentYear = WorkdayCalendar.gregorianYear(for: Date(), calendar: .current)
        loadCache(for: currentYear)
        loadCache(for: currentYear + 1)
    }

    func isLoading(year: Int) -> Bool {
        inFlightYears.contains(year)
    }

    func hasCalendar(year: Int) -> Bool {
        workingDateKeysByYear[year] != nil
    }

    func refreshIfNeeded(year: Int, completion: @escaping () -> Void) {
        guard !inFlightYears.contains(year) else {
            completion()
            return
        }

        let now = Date()
        if let fetchedAt = fetchedAtByYear[year],
           now.timeIntervalSince(fetchedAt) < Self.cacheAge {
            completion()
            return
        }
        if let lastAttempt = defaults.object(forKey: Self.requestKeyPrefix + String(year)) as? Date,
           now.timeIntervalSince(lastAttempt) < Self.retryDelay {
            unavailableYears.insert(year)
            completion()
            return
        }
        guard let url = Self.requestURL(year: year) else {
            unavailableYears.insert(year)
            completion()
            return
        }

        inFlightYears.insert(year)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let boundedRequest = BoundedWorkdayRequest(
            request: request,
            maximumBytes: Self.maximumResponseBytes
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightYears.remove(year)
                self.requestsByYear.removeValue(forKey: year)

                let parsed: Result<CacheRecord, APIError>
                switch result {
                case .success(let response):
                    parsed = Self.parse(
                        data: response.data,
                        response: response.response,
                        year: year)
                case .failure(.responseTooLarge):
                    parsed = .failure(.responseTooLarge)
                case .failure:
                    parsed = .failure(.invalidResponse)
                }

                switch parsed {
                case .success(let record):
                    self.workingDateKeysByYear[year] = Set(record.workingDateKeys)
                    self.fetchedAtByYear[year] = record.fetchedAt
                    self.unavailableYears.remove(year)
                    if let encoded = try? JSONEncoder().encode(record) {
                        self.defaults.set(encoded, forKey: Self.cacheKeyPrefix + String(year))
                    }
                case .failure:
                    self.unavailableYears.insert(year)
 // Record the failed attempt only now: an app quit while
 // the request was in flight must not suppress the retry
 // for the whole 7-day window.
                    self.defaults.set(
                        Date(), forKey: Self.requestKeyPrefix + String(year))
                }
                completion()
            }
        }
        requestsByYear[year] = boundedRequest
        boundedRequest.start()
    }

    func statusSummary(currentYear: Int) -> String {
        [currentYear, currentYear + 1]
            .map(statusSummary(for:))
            .joined(separator: "；")
    }

    private func statusSummary(for year: Int) -> String {
        if inFlightYears.contains(year) {
            return workingDateKeysByYear[year] == nil
                ? "\(year) 年 Timor 数据同步中"
                : "\(year) 年 Timor 更新中，暂用缓存"
        }
        if let fetchedAt = fetchedAtByYear[year] {
            if unavailableYears.contains(year) {
                return "\(year) 年 Timor 更新失败，继续使用缓存"
            }
            if Date().timeIntervalSince(fetchedAt) >= Self.cacheAge {
                return "\(year) 年使用 Timor 缓存"
            }
            return "\(year) 年 Timor 数据已同步"
        }
        if unavailableYears.contains(year) {
            return "\(year) 年暂无 Timor 数据，按周一至周五"
        }
        return "\(year) 年待同步 Timor，按周一至周五"
    }

    private func loadCache(for year: Int) {
        let key = Self.cacheKeyPrefix + String(year)
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(CacheRecord.self, from: data),
              Self.isComplete(record, for: year)
        else {
            return
        }
        workingDateKeysByYear[year] = Set(record.workingDateKeys)
        fetchedAtByYear[year] = record.fetchedAt
    }

    private static func requestURL(year: Int) -> URL? {
        guard var components = URLComponents(
            string: "https://timor.tech/api/holiday/year/\(year)/") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "type", value: "Y"),
            URLQueryItem(name: "week", value: "Y"),
        ]
        return components.url
    }

    private static func parse(
        data: Data,
        response: URLResponse,
        year: Int
    ) -> Result<CacheRecord, APIError> {
        guard data.count <= maximumResponseBytes else { return .failure(.incompleteYear) }
        guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }
        guard let payload = try? JSONDecoder().decode(APIResponse.self, from: data) else {
            return .failure(.invalidResponse)
        }
        guard payload.code == 0 else { return .failure(.serviceCode(payload.code)) }

        let expectedCount = daysInYear(year)
        guard expectedCount > 0,
              let holidayMap = payload.holiday,
              let typeMap = payload.type,
              !typeMap.isEmpty
        else {
            return .failure(.incompleteYear)
        }

        let holidayDateKeys = Set(holidayMap.keys.compactMap {
            parseHolidayDateKey($0, in: year)
        })
        let typeDateKeys = Set(typeMap.keys.compactMap {
            parseDateKey($0, in: year)
        })
        guard holidayDateKeys.count == holidayMap.count,
              typeDateKeys.count == typeMap.count,
              holidayDateKeys == typeDateKeys
        else {
            return .failure(.incompleteYear)
        }

        var typeByDate: [Int: Int] = [:]
        var exceptionalDateCount = 0
        for (date, dayType) in typeMap {
            guard let key = parseDateKey(date, in: year),
                  (0...3).contains(dayType.type)
            else {
                return .failure(.invalidRecord)
            }
            typeByDate[key] = dayType.type
            if dayType.type == 2 || dayType.type == 3 {
                exceptionalDateCount += 1
            }
        }

 // `week=Y` must return every weekend. Requiring at least one public
 // holiday or makeup day distinguishes a published year from an
 // empty future calendar that only contains ordinary weekends.
        let expectedWeekends = weekendDateKeys(in: year)
        guard expectedWeekends.isSubset(of: Set(typeByDate.keys)),
              exceptionalDateCount > 0
        else {
            return .failure(.incompleteYear)
        }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstDay = gregorian.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return .failure(.incompleteYear)
        }
        var workingDates = Set<Int>()
        for offset in 0..<expectedCount {
            guard let date = gregorian.date(byAdding: .day, value: offset, to: firstDay) else {
                return .failure(.incompleteYear)
            }
            let components = gregorian.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let dateYear = components.year,
                  let month = components.month,
                  let day = components.day,
                  let weekday = components.weekday
            else {
                return .failure(.invalidRecord)
            }
            let key = dateYear * 10_000 + month * 100 + day
            let isWorkingDay: Bool
            switch typeByDate[key] {
            case 0, 3:
                isWorkingDay = true
            case 1, 2:
                isWorkingDay = false
            case nil:
                isWorkingDay = weekday != 1 && weekday != 7
            default:
                return .failure(.invalidRecord)
            }
            if isWorkingDay { workingDates.insert(key) }
        }

        let record = CacheRecord(
            year: year,
            typeRecordCount: typeMap.count,
            exceptionalDateCount: exceptionalDateCount,
            workingDateKeys: workingDates.sorted(),
            fetchedAt: Date())
        return .success(record)
    }

    private static func isComplete(_ record: CacheRecord, for year: Int) -> Bool {
        let expectedCount = daysInYear(year)
        let expectedWeekendCount = weekendDateKeys(in: year).count
        guard record.year == year,
              record.typeRecordCount >= expectedWeekendCount,
              record.exceptionalDateCount > 0,
              expectedCount > 0
        else {
            return false
        }
        let uniqueDates = Set(record.workingDateKeys)
        return uniqueDates.count == record.workingDateKeys.count
            && uniqueDates.allSatisfy { isValidDateKey($0, in: year) }
    }

    private static func parseDateKey(_ value: String, in year: Int) -> Int? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let parsedYear = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              parsedYear == year
        else {
            return nil
        }
        let key = parsedYear * 10_000 + month * 100 + day
        return isValidDateKey(key, in: year) ? key : nil
    }

    private static func parseHolidayDateKey(_ value: String, in year: Int) -> Int? {
        let parts = value.split(separator: "-")
        if parts.count == 3 {
            return parseDateKey(value, in: year)
        }
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1])
        else {
            return nil
        }
        let key = year * 10_000 + month * 100 + day
        return isValidDateKey(key, in: year) ? key : nil
    }

    private static func weekendDateKeys(in year: Int) -> Set<Int> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstDay = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return []
        }
        let count = daysInYear(year)
        return Set((0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let weekday = components.weekday,
                  weekday == 1 || weekday == 7,
                  let year = components.year,
                  let month = components.month,
                  let day = components.day
            else {
                return nil
            }
            return year * 10_000 + month * 100 + day
        })
    }

    private static func isValidDateKey(_ key: Int, in year: Int) -> Bool {
        let keyYear = key / 10_000
        let month = (key / 100) % 100
        let day = key % 100
        guard keyYear == year, (1...12).contains(month), (1...31).contains(day) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    private static func daysInYear(_ year: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstDay = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let range = calendar.range(of: .day, in: .year, for: firstDay)
        else {
            return 0
        }
        return range.count
    }
}

private enum BoundedWorkdayRequestError: Error {
    case responseTooLarge
    case missingResponse
    case transport(Error)
}

/// Streams response chunks into a bounded buffer and cancels oversized replies.
private final class BoundedWorkdayRequest: NSObject, URLSessionDataDelegate {
    struct Response {
        let data: Data
        let response: URLResponse
    }

    typealias ResultHandler = (Result<Response, BoundedWorkdayRequestError>) -> Void

    private let request: URLRequest
    private let maximumBytes: Int
    private var completion: ResultHandler?
    private var body = Data()
    private var response: URLResponse?
    private var session: URLSession?
    private var isFinished = false

    init(request: URLRequest, maximumBytes: Int, completion: @escaping ResultHandler) {
        self.request = request
        self.maximumBytes = maximumBytes
        self.completion = completion
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.expectedContentLength <= Int64(maximumBytes)
                || response.expectedContentLength < 0
        else {
            completionHandler(.cancel)
            finish(.failure(.responseTooLarge), cancelSession: true)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !isFinished else { return }
        guard data.count <= maximumBytes - body.count else {
            dataTask.cancel()
            finish(.failure(.responseTooLarge), cancelSession: true)
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(.transport(error)), cancelSession: false)
        } else if let response {
            finish(.success(Response(data: body, response: response)), cancelSession: false)
        } else {
            finish(.failure(.missingResponse), cancelSession: false)
        }
    }

    private func finish(_ result: Result<Response, BoundedWorkdayRequestError>, cancelSession: Bool) {
        guard !isFinished else { return }
        isFinished = true
        completion?(result)
        completion = nil
        if cancelSession {
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
    }
}