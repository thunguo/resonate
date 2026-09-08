import SwiftUI

struct ListeningStatisticsView: View {
    @Environment(AppStore.self) private var store
    @State private var clearing = false
    var body: some View {
        Form {
            Section("播放") {
                LabeledContent("开始播放", value: "\(store.metrics.playbackStarts) 次")
                if store.metrics.playbackAttempts > 0 { LabeledContent("开始播放成功率", value: "\(Int(Double(store.metrics.playbackStarts) / Double(store.metrics.playbackAttempts) * 100))%") }
                if store.metrics.playbackStarts > 0 { LabeledContent("平均开始等待", value: String(format: "%.1f 秒", store.metrics.playbackStartSeconds / Double(store.metrics.playbackStarts))) }
                LabeledContent("从收藏重新听起", value: "\(store.metrics.collectionReplays) 次")
            }
            Section("音乐编排") {
                LabeledContent("生成编排", value: "\(store.metrics.aiGenerations) 次")
                LabeledContent("播放或应用", value: "\(store.metrics.aiApplications) 次")
                LabeledContent("保存为歌单", value: "\(store.metrics.aiSaves) 次")
            }
            Section { Button("清除本机统计", role: .destructive) { clearing = true } } footer: { Text("统计只保存在当前账号的这台设备上，不会上传。开始播放按实际出声状态计数，包含网络、缓冲和主动取消造成的未开始情况。") }
        }.cabinetList().navigationTitle("本机聆听统计")
            .confirmationDialog("清除这台设备上的聆听统计？", isPresented: $clearing, titleVisibility: .visible) { Button("清除统计", role: .destructive) { store.clearMetrics() } }
    }
}
