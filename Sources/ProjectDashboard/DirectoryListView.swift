import SwiftUI
import AppKit

/// 扫描目录管理：列表展示已添加的目录，可增删
struct DirectoryListView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("扫描目录")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if model.rootPaths.isEmpty {
                Text("尚未添加目录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rootPaths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    model.removeRoot(path)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("移除该目录")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            Divider()

            Button {
                chooseDirectories()
            } label: {
                Label("添加目录…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private func chooseDirectories() {
        chooseAndAddDirectories(model: model)
    }
}
