import SwiftUI

// "按键策略" — list editor for SiteKeyPolicy. Shown as a subscreen
// of the Settings tab (push navigation). Sorting is delegated to
// PolicyStore so the user never has to think about ordering: when
// they add an entry for a longer hostSuffix it automatically wins
// over a shorter one in resolve(). The "*" catch-all is pinned to
// the bottom by the same sort, displayed as "(默认)" and stripped
// of the delete swipe.
struct KeyPolicyListView: View {
    @EnvironmentObject var store: PolicyStore
    @State private var addingNew: Bool = false
    @State private var draftForNew: SiteKeyPolicy = SiteKeyPolicy(
        hostSuffix: "",
        onBtnAClick: .pressEnter
    )

    var body: some View {
        List {
            Section {
                ForEach(store.items) { policy in
                    NavigationLink {
                        KeyPolicyDetailView(policy: policy)
                    } label: {
                        row(policy)
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        let p = store.items[i]
                        if !p.isCatchAll { store.remove(p.id) }
                    }
                }
            } footer: {
                Text("BtnA 短按时按域名后缀匹配，更具体的规则自动优先；* (默认) 行不可删，但可以改动作。")
            }

            Section {
                Button {
                    draftForNew = SiteKeyPolicy(hostSuffix: "", onBtnAClick: .pressEnter)
                    addingNew = true
                } label: {
                    Label("添加规则", systemImage: "plus.circle.fill")
                }
                Button(role: .destructive) {
                    store.resetToPresets()
                } label: {
                    Label("恢复预设", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("按键策略")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingNew) {
            NavigationStack {
                KeyPolicyDetailView(policy: draftForNew, isNew: true)
            }
        }
    }

    private func row(_ policy: SiteKeyPolicy) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if policy.isCatchAll {
                        Text("* (默认)").font(.body.weight(.medium))
                    } else {
                        Text(policy.hostSuffix).font(.body)
                    }
                }
                Text(policy.onBtnAClick.userLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .deleteDisabled(policy.isCatchAll)
    }
}
