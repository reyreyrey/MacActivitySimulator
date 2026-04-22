import SwiftUI
import Combine

class LogManager: ObservableObject {
    static let shared = LogManager()
    
    @Published var logs: [String] = []
    
    func add(_ message: String) {
        DispatchQueue.main.async {
            self.logs.append(message)
            if self.logs.count > 500 { // 限制日志数量
                self.logs.removeFirst(self.logs.count - 500)
            }
        }
    }
}

/// 替代 print
func log(_ items: Any...) {
    let message = items.map { "\($0)" }.joined(separator: " ")
    LogManager.shared.add(message)
    Swift.print(message)
}
