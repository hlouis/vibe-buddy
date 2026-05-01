import SwiftUI

// Edit screen for one SiteKeyPolicy. Two modes:
//   • isNew == false (default): pushed from the list, edits an
//     existing entry, has a Delete button (unless isCatchAll).
//   • isNew == true: presented as a modal sheet from the list's
//     "添加规则" button, has Cancel / Save toolbar items.
//
// The form uses ActionPreset as the user-facing pivot rather than
// the raw KeyAction enum, then funnels back to a concrete KeyAction
// on save. So the user never sees `keyCode: 13` etc. — they pick
// "按下 Enter" and we materialise the right shape.
struct KeyPolicyDetailView: View {
    @EnvironmentObject var store: PolicyStore
    @Environment(\.dismiss) private var dismiss

    let original: SiteKeyPolicy
    let isNew: Bool

    @State private var hostSuffix: String
    @State private var preset: ActionPreset

    // Action-specific scratch state. Only the field for the active
    // preset is persisted into the saved KeyAction; the others stay
    // as remembered text in case the user flips back.
    @State private var insertTextValue: String
    @State private var beforeInputType: String
    @State private var beforeInputData: String
    @State private var clickSelector: String

    init(policy: SiteKeyPolicy, isNew: Bool = false) {
        self.original = policy
        self.isNew = isNew
        _hostSuffix = State(initialValue: policy.hostSuffix)
        _preset = State(initialValue: policy.onBtnAClick.preset)

        // Seed each per-preset scratch field from the current action
        // when applicable; otherwise sensible blanks/placeholders.
        if case let .insertText(s) = policy.onBtnAClick {
            _insertTextValue = State(initialValue: s)
        } else {
            _insertTextValue = State(initialValue: "\n")
        }
        if case let .beforeInput(t, d) = policy.onBtnAClick {
            _beforeInputType = State(initialValue: t)
            _beforeInputData = State(initialValue: d ?? "")
        } else {
            _beforeInputType = State(initialValue: "insertLineBreak")
            _beforeInputData = State(initialValue: "")
        }
        if case let .click(sel) = policy.onBtnAClick {
            _clickSelector = State(initialValue: sel)
        } else {
            _clickSelector = State(initialValue: "")
        }
    }

    var body: some View {
        Form {
            hostSection
            actionSection
            actionParametersSection
            if !isNew && !original.isCatchAll {
                Section {
                    Button(role: .destructive) {
                        store.remove(original.id)
                        dismiss()
                    } label: {
                        Label("删除此规则", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(isNew ? "新增规则" : "编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
    }

    // MARK: sections

    private var hostSection: some View {
        Section {
            if original.isCatchAll {
                LabeledContent("域名后缀") {
                    Text("* (默认)").foregroundStyle(.secondary)
                }
            } else {
                TextField("如 chat.openai.com", text: $hostSuffix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        } header: {
            Text("匹配域名")
        } footer: {
            if original.isCatchAll {
                Text("默认规则匹配所有未配置的站点，不可改名也不可删除。")
            } else {
                Text("以该字符串结尾的 host 都会命中。例：填 deepseek.com 会匹配 chat.deepseek.com、www.deepseek.com 等。")
            }
        }
    }

    private var actionSection: some View {
        Section("BtnA 短按动作") {
            Picker("动作类型", selection: $preset) {
                ForEach(ActionPreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var actionParametersSection: some View {
        switch preset {
        case .pressEnter, .pressShiftEnter:
            EmptyView()
        case .insertText:
            Section {
                TextField("文本（可输入 \\n 表示换行）", text: $insertTextValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("文本内容")
            } footer: {
                Text("通过 textarea/input 的 value setter 直接写入并派发 input 事件，绕过 isTrusted 检查。")
            }
        case .beforeInput:
            Section {
                TextField("inputType（如 insertLineBreak）", text: $beforeInputType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("data（可空）", text: $beforeInputData)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("InputEvent 参数")
            } footer: {
                Text("常用值：insertLineBreak（软换行）、insertParagraph（硬段落，多用于 ProseMirror）。")
            }
        case .click:
            Section {
                TextField("如 [role='button']:has(svg path[d^='M…'])",
                          text: $clickSelector,
                          axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
            } header: {
                Text("CSS 选择器")
            } footer: {
                Text("通过 document.querySelector 找元素并调用 .click()。建议先在 Mac Safari Inspector 验证唯一命中后再粘贴。")
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isNew {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        if !original.isCatchAll {
            let trimmed = hostSuffix.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            // "*" is reserved for the catch-all only.
            if trimmed == "*" && !original.isCatchAll { return false }
        }
        if preset == .click && clickSelector.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    // MARK: save

    private func save() {
        let action: KeyAction
        switch preset {
        case .pressEnter:      action = .pressEnter
        case .pressShiftEnter: action = .pressShiftEnter
        case .insertText:
            action = .insertText(unescape(insertTextValue))
        case .beforeInput:
            let d = beforeInputData.isEmpty ? nil : beforeInputData
            action = .beforeInput(inputType: beforeInputType, data: d)
        case .click:
            action = .click(selector: clickSelector)
        }

        let saved = SiteKeyPolicy(
            id: isNew ? UUID() : original.id,
            hostSuffix: original.isCatchAll ? "*" : hostSuffix.trimmingCharacters(in: .whitespaces),
            onBtnAClick: action
        )
        if isNew {
            store.add(saved)
        } else {
            store.update(saved)
        }
        dismiss()
    }

    // Translate the literal characters "\n" / "\t" / "\\" the user
    // typed in a single-line TextField back into their control char
    // forms. Without this, .insertText("\n") would write a backslash
    // and an "n" instead of a newline.
    private func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\", let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex {
                switch s[next] {
                case "n":  out.append("\n");  i = s.index(after: next); continue
                case "t":  out.append("\t");  i = s.index(after: next); continue
                case "r":  out.append("\r");  i = s.index(after: next); continue
                case "\\": out.append("\\");  i = s.index(after: next); continue
                default: break
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}
