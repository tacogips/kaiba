import Foundation

/// A Gregorian calendar date, valid through the end of that day in UTC.
enum APIClientExpirationDate {
  static func validate(_ value: String) throws {
    let bytes = Array(value.utf8)
    guard bytes.count == 10,
          bytes[4] == 45, bytes[7] == 45,
          bytes.enumerated().allSatisfy({ index, byte in
            index == 4 || index == 7 || (48...57).contains(byte)
          }) else {
      throw invalidDate
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    var components = DateComponents()
    components.year = Int(value.prefix(4))
    components.month = Int(value.dropFirst(5).prefix(2))
    components.day = Int(value.suffix(2))
    guard let year = components.year, year > 0,
          let date = calendar.date(from: components),
          calendar.dateComponents([.year, .month, .day], from: date) == components else {
      throw invalidDate
    }
  }

  private static var invalidDate: NoteServiceError {
    .invalidInput("API client expiration must be a valid YYYY-MM-DD date")
  }
}
