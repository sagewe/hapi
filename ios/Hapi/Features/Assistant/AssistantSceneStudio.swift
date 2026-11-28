import HapiClient
import HapiProtocol
import SwiftUI

// MARK: - Scene Studio Prompt Builders

enum SceneStudioPrompts {
    static func createNew(referenceDoc: ReferenceDoc? = nil) -> String {
        let refLine = referenceDoc.map {
            "我想基于参考底稿《\($0.fileName)》（ID: \($0.id)）定制一个新场景，请先帮我梳理核查要点并生成场景草案。"
        } ?? "我想定制一个新的调查场景，请先问我 1–2 个最关键的问题，或者我直接把要求和审单表发给你。"
        return """
        【场景工坊 · 定制新场景】

        \(refLine)

        <scene-studio-instructions>
        你正处于「场景工坊」创造模式，面向非技术业务同事。
        1. 用简洁中文沟通，不展示代码、路径或开发术语。
        2. 如涉及稳定核查清单或固定报告格式，可在 `.gemini/skills/custom-<slug>/SKILL.md` 创建专属技能，绝不修改内置 4 个核心技能或根目录 AGENTS.md。
        3. 一旦需求明确（或在用户上传底稿/说明后），必须在回复末尾输出一个 `qiqi-scene-draft` 代码块（JSON 包含 id、title、subtitle、icon、opensAttachment、skillSlug、referenceDocIds、summaryPoints、prompt），客户端会渲染为「场景草案卡」由用户点选保存生效。
        </scene-studio-instructions>
        """
    }

    static func optimize(scene: AssistantScene) -> String {
        let skillLine = scene.action.skillSlug.map { "关联技能：\($0)。" } ?? ""
        return """
        【场景工坊 · 优化「\(scene.title)」】

        我想调整「\(scene.title)」这个场景的核查步骤或输出格式，请问你想怎么改？

        <scene-studio-instructions>
        当前正在优化已有场景：id=\(scene.id)，title=\(scene.title)，subtitle=\(scene.placeholder)，icon=\(scene.action.icon ?? "checklist")，opensAttachment=\(scene.opensAttachment)。\(skillLine)
        当前指令：
        \(scene.action.prompt)

        请先用 2–3 条人话概括当前场景做法，询问用户希望增删或调整哪些环节。用户确认改动后，按需更新 `.gemini/skills/custom-<slug>/SKILL.md`（若为内置场景则另存为 custom-<slug> 或仅输出更新后的 `qiqi-scene-draft` 保留相同 id），并输出 `qiqi-scene-draft` 代码块供用户一键保存生效。
        </scene-studio-instructions>
        """
    }

    static func promoteFromCase(caseTitle: String, caseFiles: [CaseFile]) -> String {
        let fileList = caseFiles.prefix(8).map(\.fileName).joined(separator: "、")
        return """
        【场景工坊 · 从本案沉淀场景】

        请结合刚才「\(caseTitle)」的查证步骤与交付物（\(fileList.isEmpty ? "无附件" : fileList)），提炼成一个可复用的调查场景草案。

        <scene-studio-instructions>
        用户希望把刚刚完成的合规调查「\(caseTitle)」的做法沉淀为一个可复用自定义场景。
        1. 提炼出通用的核查步骤、关注的风险点和交付物要求（脱敏去掉本案具体公司/自然人姓名）。
        2. 在 `.gemini/skills/custom-<slug>/SKILL.md` 写入可复用工作流（不碰内置 4 个核心技能和 AGENTS.md）。
        3. 直接在回复末尾输出一个 `qiqi-scene-draft` 代码块供用户预览并一键保存到工作台。
        </scene-studio-instructions>
        """
    }
}

// MARK: - Scene Draft Card Environment Action

struct SceneDraftSaveHandler {
    let save: @MainActor (SceneDraft) async throws -> Void
    let edit: @MainActor (SceneDraft) -> Void
}

private struct SceneDraftSaveHandlerKey: EnvironmentKey {
    static let defaultValue: SceneDraftSaveHandler? = nil
}

extension EnvironmentValues {
    var sceneDraftSaveHandler: SceneDraftSaveHandler? {
        get { self[SceneDraftSaveHandlerKey.self] }
        set { self[SceneDraftSaveHandlerKey.self] = newValue }
    }
}

// MARK: - Scene Draft Preview Card (Rendered inside AgentTextBlockView)

struct SceneDraftCardView: View {
    let draft: SceneDraft
    @Environment(\.sceneDraftSaveHandler) private var handler
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: AssistantScene.sfSymbol(for: draft.icon ?? "checklist"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AssistantDesign.accent)
                    .frame(width: 40, height: 40)
                    .background(AssistantDesign.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AssistantDesign.ink)
                    HStack(spacing: 5) {
                        if draft.opensAttachment {
                            pill("自动拉起附件", accent: true)
                        }
                        if let slug = draft.skillSlug, !slug.isEmpty {
                            pill("专属工作流", accent: false)
                        }
                        if !draft.referenceDocIds.isEmpty {
                            pill("关联 \(draft.referenceDocIds.count) 底稿", accent: false)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if !draft.summaryPoints.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(draft.summaryPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(AssistantDesign.accent)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(point)
                                .font(.caption)
                                .foregroundStyle(AssistantDesign.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantDesign.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
                )
            }

            HStack(spacing: 8) {
                Button {
                    guard let handler, !saving else { return }
                    saving = true
                    error = nil
                    Task {
                        defer { saving = false }
                        do {
                            try await handler.save(draft)
                            withAnimation(.snappy(duration: 0.22)) { saved = true }
                        } catch {
                            self.error = "保存失败，请重试"
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if saving {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: saved ? "checkmark.circle.fill" : "checkmark")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(saved ? "已保存到工作台" : "保存到工作台")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(AssistantDesign.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(saved ? 0.85 : 1)
                }
                .buttonStyle(AssistantPressStyle(scale: 0.97))
                .disabled(saving || handler == nil)

                if let handler {
                    Button {
                        handler.edit(draft)
                    } label: {
                        Text("微调")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssistantDesign.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .background(AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(AssistantDesign.border, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(AssistantPressStyle(scale: 0.96))
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AssistantDesign.report)
            }
        }
        .padding(14)
        .background(AssistantDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AssistantDesign.accentBorder, lineWidth: 1.0)
        )
        .shadow(color: AssistantDesign.accent.opacity(0.08), radius: 12, y: 4)
        .accessibilityIdentifier("assistant.scene-draft-card")
    }

    private func pill(_ title: String, accent: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent ? AssistantDesign.accent : AssistantDesign.inkMuted)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(accent ? AssistantDesign.accentSoft : AssistantDesign.surfaceMuted, in: Capsule())
    }
}

// MARK: - Scenario Editor Sheet (Manual Tweak / Rename / Icon Picker)

struct ScenarioEditorSheet: View {
    let initial: ClientQuickAction
    let onSave: @MainActor (ClientQuickAction) async throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var subtitle: String
    @State private var icon: String
    @State private var opensAttachment: Bool
    @State private var prompt: String
    @State private var saving = false
    @State private var error: String?

    init(initial: ClientQuickAction, onSave: @escaping @MainActor (ClientQuickAction) async throws -> Void) {
        self.initial = initial
        self.onSave = onSave
        _title = State(initialValue: initial.title)
        _subtitle = State(initialValue: initial.subtitle ?? "")
        _icon = State(initialValue: initial.icon ?? "checklist")
        _opensAttachment = State(initialValue: initial.opensAttachment ?? false)
        _prompt = State(initialValue: initial.prompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("场景名称", text: $title)
                    TextField("输入框提示语（可选）", text: $subtitle)
                    Toggle("选中时自动拉起附件", isOn: $opensAttachment)
                }

                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(AssistantScene.curatedIcons, id: \.key) { item in
                            let selected = icon == item.key
                            Button {
                                icon = item.key
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(item.label)
                                        .font(.caption2)
                                }
                                .foregroundStyle(selected ? AssistantDesign.accent : AssistantDesign.inkSecondary)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(selected ? AssistantDesign.accentSoft : AssistantDesign.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(selected ? AssistantDesign.accent : .clear, lineWidth: 1.2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("调查要求（人话即可）") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .font(.subheadline)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(AssistantDesign.report).font(.caption)
                    }
                }
            }
            .navigationTitle("编辑场景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanTitle.isEmpty else {
                            error = "请填写场景名称"
                            return
                        }
                        saving = true
                        error = nil
                        var updated = initial
                        updated.title = cleanTitle
                        updated.subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.icon = icon
                        updated.opensAttachment = opensAttachment
                        updated.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.hidden = false
                        Task {
                            defer { saving = false }
                            do {
                                try await onSave(updated)
                                dismiss()
                            } catch {
                                self.error = "保存失败，请重试"
                            }
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }
}
