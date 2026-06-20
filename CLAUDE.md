# CLAUDE.md — EdgeScaffold

## 项目简介

EdgeScaffold 是 Edge Studio 导出流水线的终端产物——一个**可直接发布的 iOS App 脚手架模板**。

Edge Studio 优化模型后，将模型配置写入本模板，用户拿到一个完整的 Xcode 项目，即可编译、真机运行、上架 App Store。

**核心定位：** 小白开发者通过 Claude Code / Codex 用自然语言指挥 AI 完成二次开发，无需理解 Swift 细节。

## 三仓库关系

```
Edge Studio (优化 & 导出)
    ├── 读取模板 ──→ EdgeScaffold (本仓库，iOS App 脚手架)
    └── 动态读取版本 ──→ EdgeKit (Swift SDK，加载优化模型的运行时入口)
                              ↑
              EdgeScaffold ──import──┘
```

- **Edge Studio**: 优化工作台
- **EdgeKit**: Swift 推理 SDK，公开包 `AtomGradient/edge-kit`
- **EdgeHalo**: 自学习 / RPP / Halo Capsule 编排，公开包 `AtomGradient/edge-halo`
- **EdgeScaffold**: 本仓库 — iOS App 模板
- **依赖路径约定**：默认发布链路声明公开 `EdgeKit` + `EdgeHalo` SPM；不得在模板默认依赖图里直接声明官方 MLX Swift 包
- **架构边界**：EdgeScaffold 是参考 App / export template，不是底层库；dogfood-app 和其他业务 App 不 import EdgeScaffold。可复用能力下沉到 EdgeKit / EdgeHalo / EdgeEngine。

## 技术栈

- **语言:** Swift 5 / SwiftUI
- **最低部署:** iOS 18.0
- **构建:** XcodeGen (`project.yml` → `.xcodeproj`)
- **并发模型:** Swift Concurrency（async/await + @MainActor），strict concurrency checking = complete
- **依赖:** EdgeKit (public SPM)、EdgeHalo (public SPM)、swift-async-algorithms、swift-markdown-ui

## 项目结构

```
EdgeScaffold/
├── CLAUDE.md                          # 本文件
├── .min_runtime_version               # 版本契约（当前 1.0.0-rc98）
├── .scaffold_version                  # 模板版本号（当前 2）
├── project.yml                        # XcodeGen 配置（依赖、构建设置、post-build 脚本）
├── edgescaffolding_model_config       # 本地调试模型路径配置
├── README.md                          # 用户文档
│
└── EdgeScaffold/
    ├── App/
    │   ├── EdgeScaffoldApp.swift    # @main 入口，路由 Onboarding / Home
    │   ├── AppDelegate.swift          # 前后台生命周期（卸载/重载模型）
    │   └── ScaffoldConfig.swift       # ⭐ 开发者唯一配置文件
    │
    ├── AI/
    │   ├── AIManager.swift            # ⭐ 核心管理器（四层加载策略 + 多模态推理）
    │   ├── ScaffoldHaloRuntimeAdapter.swift # App-side EdgeKit ↔ EdgeHalo bridge
    │   ├── AIStateManager.swift       # UserDefaults 持久化（tier、token 计数等）
    │   ├── DeviceCapabilityChecker.swift  # 硬件评估 + 存储检查
    │   ├── AIIQScorer.swift           # AI IQ 评分算法（0-185）
    │   ├── MeshManager.swift          # EdgeMesh 组网管理
    │   ├── PersonalizationManager.swift   # 用户反馈/纠错收集
    │   └── AppSummarizer.swift        # Mesh 领域摘要聚合
    │
    ├── Business/
    │   └── HomeView.swift             # 主 TabView（Home + Chat + Settings）
    │
    ├── Chat/
    │   └── DemoChatView.swift         # ⭐ 多模态聊天界面（LLM/VLM/TTS/STT 四合一）
    │
    ├── Onboarding/                    # 4 步引导流程
    │   ├── OnboardingView.swift       # 容器（TabView 分步）
    │   ├── DeviceCheckStep.swift      # 步骤 1：硬件评估 + AI IQ
    │   ├── ModelSelectStep.swift      # 步骤 2：模型 tier 选择
    │   └── DownloadStep.swift         # 步骤 3：模型下载（网络感知）
    │
    ├── Settings/                      # 设置页面
    │   ├── SettingsView.swift         # 设置主页（7 个分区）
    │   ├── AIEngineSection.swift      # AI 开关 + 状态显示
    │   ├── ModelTierSelectionView.swift    # 切换模型 tier
    │   ├── DownloadConfirmView.swift  # 下载确认弹窗
    │   ├── DeviceReportView.swift     # 设备详情 + benchmark
    │   ├── MeshSettingsView.swift     # Mesh 组网设置
    │   ├── PersonalizationView.swift  # Neural Imprint 状态 & 数据飞轮
    │   ├── CacheManagerView.swift     # 模型缓存清理
    │   └── SustainabilityView.swift   # 碳减排指标
    │
    ├── Sustainability/
    │   └── CarbonSavingsManager.swift # 碳排放 & 成本节省计算
```

## 架构要点

### 单一配置入口

`ScaffoldConfig.swift` 是**唯一需要关心的配置文件**。所有定制从这里开始：

| 属性 | 作用 | 示例 |
|------|------|------|
| `appName` | App 显示名 | `"MyAIApp"` |
| `appDescription` | 首页描述文字 | `"Your personal AI"` |
| `modelCategory` | 模型类别 | `.llm` / `.vlm` / `.tts` / `.stt` |
| `modelMapping` | tier → 模型 ID 映射 | `[.standard: "qwen3.5-0.8b"]` |
| `defaultSystemPrompt` | LLM/VLM 系统提示词 | `"You are a helpful assistant."` |
| `bundleModelName` | 内嵌模型文件夹名 | `nil` = 不内嵌 |
| `enableDSREviction` | KV cache 淘汰策略 | `true` |
| `enableSustainability` | 碳减排功能开关 | `true` |

### 四层模型加载策略

`AIManager.loadModel()` 按优先级依次尝试（`AIManager.swift:94-181`）：

1. **Local Cache** — `ModelCache.shared.isCached()` → 最快
2. **Bundle** — `ScaffoldConfig.bundleModelName` → 离线可用
3. **ODR** — `ScaffoldConfig.odrTags` → App Thinning
4. **Remote** — HuggingFace 下载 → 兜底，有进度回调

### 多模态引擎分发

`AIManager` 根据 `ScaffoldConfig.modelCategory` 在 init 时只激活一个引擎：

- `.llm` → `LLMEngine` → 文本聊天
- `.vlm` → `VLMEngine` → 图文理解
- `.tts` → `TTSEngine` → 语音合成（支持流式播放）
- `.stt` → `STTEngine` → 语音转文字（支持流式转写）

### 状态管理

5 个 `@MainActor` 单例管理器，通过 `@EnvironmentObject` 注入 SwiftUI 视图：

- `AIManager.shared` — 模型加载 & 推理
- `AIStateManager.shared` — 用户偏好持久化
- `MeshManager.shared` — Mesh 组网
- `PersonalizationManager.shared` — 反馈 & 纠错数据
- `CarbonSavingsManager.shared` — ESG 统计

### Onboarding 流程

4 步引导：Welcome → DeviceCheck（硬件评估 + AI IQ）→ ModelSelect（tier 选择）→ Download（模型下载）

完成后 `@AppStorage("hasCompletedOnboarding")` 标记为 true，后续直接进 HomeView。

## 常见定制场景 → 修改指南

> 这是本文件最重要的部分。Claude Code 应根据用户自然语言请求，定位到对应文件和代码段。

### "我想换一个模型"

→ 改 `ScaffoldConfig.swift` 的 `modelMapping`，把 tier 映射到新的模型 ID。

### "我想改 App 的名字和描述"

→ 改 `ScaffoldConfig.swift` 的 `appName` 和 `appDescription`。
→ 同时改 `project.yml` 的 `PRODUCT_NAME` 和 `MARKETING_VERSION`（如果要改版本号）。

### "我想改系统提示词"

→ 改 `ScaffoldConfig.swift` 的 `defaultSystemPrompt`。

### "我想改聊天界面的样式"

→ 改 `DemoChatView.swift`。
→ 消息气泡样式在 `MessageBubble` struct（第 543 行起）。
→ 输入栏在 `body` 的 `// Input bar` 注释处（第 163 行起）。
→ 状态栏在 `// Status bar` 注释处（第 84 行起）。

### "我想改首页"

→ 改 `HomeView.swift`。当前是占位内容，注释写着 "Replace this view with your app content"。

### "我想改 Onboarding 流程"

→ `OnboardingView.swift` 是容器，4 个步骤分别在 `DeviceCheckStep`、`ModelSelectStep`、`DownloadStep`。
→ 要跳过 Onboarding：在 `EdgeScaffoldApp.swift` 把 `hasCompletedOnboarding` 默认值改为 true。

### "我想关掉碳减排功能"

→ 改 `ScaffoldConfig.swift` 的 `enableSustainability = false`。

### "我想加一个新的 Tab"

→ 改 `HomeView.swift` 的 `TabView`，仿照现有 tab 添加。

### "我想改 App 的图标或启动页"

→ 图标在 `Resources/Assets.xcassets/AppIcon.appiconset/`。
→ 启动页在 `Resources/LaunchScreen.storyboard`。

### "模型加载失败怎么排查"

→ 查看 `AIManager.swift` 的 `loadError` 属性。
→ Xcode console 搜索 `[AIManager]` 前缀的 debugPrint 输出。
→ 四层策略依次尝试，每层失败都有日志。

## 版本契约

`.min_runtime_version` 文件声明 EdgeKit 的最低兼容版本。Edge Studio 导出时读取此文件，写入 `project.yml` 的 SPM 依赖版本。

**升级流程：**
1. EdgeKit 打新 tag（`git tag X.Y.Z`）
2. EdgeScaffold 适配新 API → 更新 `.min_runtime_version`
3. Edge Studio 无需改动，自动读取

## 构建命令

```bash
# 生成 Xcode 项目（需要 xcodegen）
xcodegen generate

# 打开项目
open EdgeScaffold.xcodeproj

# 或命令行构建
xcodebuild -project EdgeScaffold.xcodeproj -scheme EdgeScaffold -sdk iphoneos build
```

## 测试

EdgeScaffold 本身不包含单元测试。测试守卫在 Edge Studio 侧：
- `tests/test_scaffold_export.py` — 31 项导出结构验证
- `tests/test_scaffold_export.py::TestVersionContract` — 8 项版本契约守卫
- `tests/smoke_test/` — 独立 Swift CLI 验证 EdgeKit 推理
- `tests/run_integration_test.sh` — E2E 三方联调（导出 → 编译 → 真机部署）

## 代码风格

- 中文 commit message，格式：`类型: 简要描述`（feat/fix/refactor/chore）
- 中文行内注释作为语义锚点，方便 LLM 检索定位
- `@MainActor` + `ObservableObject` + `@Published` 为标准状态管理模式
- 不使用 Combine，全部用 Swift Concurrency（async/await、AsyncThrowingStream）

## 开发环境

| 机器 | 芯片 | 内存 |
|------|------|------|
| Mac Studio (103) | M2 Ultra | 192 GB |
| MacBook Pro (100) | M1 Max | 32 GB |
| MacBook Pro (107) | M2 Pro | 32 GB |

## TODO：架构改进

以下改进已识别，按优先级排列。标记为待实施。

### TODO 1：拆分 DemoChatView（高优先级）

**现状：** `DemoChatView.swift` 739 行，LLM/VLM/TTS/STT 四种模态混合在一个文件中。

**问题：** LLM 做局部修改时需要加载全部 739 行，且 TTS/STT 相关代码散布在 4 个不连续区域（voice picker、generation、AudioPlayButton、StreamingAudioPlayer），增加误改风险。

**方案：**
```
Chat/
├── DemoChatView.swift          # 路由层，根据 modelCategory 选择子视图
├── LLMChatView.swift           # 纯文本聊天（~150 行）
├── VLMChatView.swift           # 图文聊天（~180 行）
├── TTSView.swift               # 语音合成 + StreamingAudioPlayer（~200 行）
├── STTView.swift               # 语音转文字 + 录音（~150 行）
├── MessageBubble.swift         # 共享消息气泡组件
└── AudioPlayButton.swift       # 共享音频播放按钮
```
每个子视图独立、可被 LLM 单独理解和修改。`DemoChatView` 退化为一个 switch 路由器。

### TODO 2：结构化错误信息（中优先级）

**现状：** 加载错误以 `debugPrint` 输出到 console，`loadError` 只存最终错误的 `localizedDescription`。

**问题：** 用户遇到加载失败时，Claude Code 无法从 `loadError` 判断是哪层策略失败、失败原因是什么。

**方案：**
- 定义 `LoadAttempt` 结构：`{ source: ModelLoadSource, error: Error? }`
- `AIManager` 记录每层尝试结果到 `@Published var loadAttempts: [LoadAttempt]`
- `loadError` 改为包含完整降级路径的描述，例如：
  `"Cache: not found → Bundle: disabled → ODR: network timeout → Remote: HTTP 403"`
- UI 层可在设置页展示加载诊断信息

### TODO 3：AIIQScorer 参数化测试（低优先级）

**现状：** `AIIQScorer` 包含对数归一化、兼容性门控、权重组合等数学逻辑，无任何测试。

**问题：** 调整评分参数（权重、阈值、设备开销常量）时无法验证输出是否符合预期。

**方案：**
- 在 EdgeScaffold 内新增 XCTest target
- 针对 `AIIQScorer.compute()` 编写参数化测试：给定 benchmark 输入，断言 IQ 范围和推荐 tier
- 覆盖边界场景：4GB iPhone、8GB iPad、192GB Mac Studio

### TODO 4：聊天记录持久化（低优先级）

**现状：** `@State private var messages: [DisplayMessage]` 全在内存，app 切后台模型卸载后消息丢失。

**问题：** 长对话（尤其 VLM 带图片）内存持续增长，无分页。

**方案：**
- 用 SwiftData 或 JSON 文件持久化消息历史
- 图片数据存磁盘，消息只存引用
- 加载时分页（最近 50 条），上滑加载更多
