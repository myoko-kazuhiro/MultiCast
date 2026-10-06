import SwiftUI

struct LogViewerView: View {
    @ObservedObject var logStore = LogStore.shared
    @State private var searchText = ""
    @State private var selectedLevel = "ALL"
    
    let levels = ["ALL", "INFO", "WARN", "ERROR", "FATAL", "DEBUG"]
    
    var filteredLogs: [LogEntry] {
        logStore.logEntries.filter { entry in
            let matchesLevel = selectedLevel == "ALL" || entry.level == selectedLevel
            let matchesSearch = searchText.isEmpty || entry.rawText.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack {
                Picker("", selection: $selectedLevel) {
                    ForEach(levels, id: \.self) { level in
                        Text(level).tag(level)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
                .fixedSize() // 中身の文字が省略・改行されないようにサイズを固定
                
                Spacer()
                
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 200)
                
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logStore.getLogText(), forType: .string)
                }) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                
                Button(action: {
                    logStore.clearLogs()
                }) {
                    Label("Clear", systemImage: "trash")
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Log List
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredLogs) { entry in
                            Text(entry.rawText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(colorForLevel(entry.level))
                                .lineLimit(1) // 自動改行を防ぐ
                                .textSelection(.enabled) // テキスト選択を可能にする
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: filteredLogs.count) { _ in
                    if let last = filteredLogs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 850, minHeight: 500)
    }
    
    private func colorForLevel(_ level: String) -> Color {
        switch level {
        case "INFO": return .primary
        case "WARN": return .yellow
        case "ERROR", "FATAL": return .red
        case "DEBUG": return .gray
        default: return .primary
        }
    }
}
