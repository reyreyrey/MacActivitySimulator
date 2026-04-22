import SwiftUI

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(logManager.logs.indices, id: \.self) { i in
                    Text(logManager.logs[i])
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(5)
        }
        .border(Color.gray, width: 1)
    }
}
