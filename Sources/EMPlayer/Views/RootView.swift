import SwiftUI
import EMPlayerCore

/// The root view that decides which screen to show based on auth state.
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    
    var body: some View {
        Group {
            if !appState.isLoggedIn {
                if serverStore.servers.isEmpty {
                    ServerAddView()
                } else {
                    ServerListView()
                }
            } else {
                MainTabView()
            }
        }
        .overlay(alignment: .top) {
            if let msg = appState.errorMessage {
                ErrorBanner(message: msg) {
                    appState.clearError()
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut, value: msg)
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onClose: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.orange.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

#Preview {
    RootView()
        .environmentObject(AppState.shared)
        .environmentObject(ServerStore.shared)
}
