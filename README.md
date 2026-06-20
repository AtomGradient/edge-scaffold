# EdgeScaffold

> Reference iOS app scaffold for EdgeKit, EdgeHalo, EdgeMesh, and Neural Imprint.

Powered by [EdgeKit](https://github.com/AtomGradient/edge-kit) and [Edge Studio](https://github.com/AtomGradient/EdgeStudio).

## Role

EdgeScaffold is a reference app and export template. It is not a shared library, and production apps such as `dogfood-app` must not depend on it. Shared runtime, data, mesh, tool, and self-learning capabilities belong in the foundation packages:

```
edge-scaffold / other apps / dogfood-app
       /              \
  edge-kit          edge-halo
       \              /
          edge-engine
```

Use EdgeScaffold to see the standard app-side wiring for:

- Four-tier model loading: Documents, local cache, bundle, ODR, remote
- Streaming LLM/VLM/TTS/STT surfaces
- EdgeData classification and facts
- ToolRegistry registration and tool schema snapshot
- EdgeHalo RPP self-learning demo with EdgeStudio-provided A-library manifests
- Neural Imprint restore from `Documents/neural_imprint`
- EdgeMesh pairing and RPP artifact backflow to EdgeStudio
- Neural Imprint smoke, feedback, and correction collection surfaces

## Canonical Neural Imprint Sample

The current Neural Imprint reference flow is documented in:

- [docs/neural-imprint-canonical-sample.md](docs/neural-imprint-canonical-sample.md)

The short version:

1. Configure the app and model in `EdgeScaffold/App/ScaffoldConfig.swift`.
2. Register app schemas and tools from `EdgeScaffold/AI/EdgeDataBootstrap.swift`.
3. Replace scaffold demo data with real classified facts.
4. Run RPP self-learning from Settings, using the A-library exported for the current model.
5. Restore `neural_imprint.safetensors` from `Documents/neural_imprint` after model load.
6. Use EdgeMesh to send RPP receipts and artifacts back to EdgeStudio.

The public scaffold does not commit RPP A-library artifacts. EdgeStudio or an
authorized internal build pipeline should place the model-matched manifest and
referenced `.safetensors` files under `Resources/RPP` before app export.

## How Export Works

```
EdgeStudio
    -> copies EdgeScaffold
    -> writes ScaffoldConfig and model settings
    -> pins the EdgeKit runtime version from .min_runtime_version
    -> bundles or configures model delivery
    -> generates the Xcode project
```

## Model Categories

The app UI adapts based on `ScaffoldConfig.modelCategory`:

| Category | Input | Output | UI |
|----------|-------|--------|-----|
| **LLM** | Text | Text | Standard chat |
| **VLM** | Text + Photo | Text | Chat + PhotosPicker |
| **TTS** | Text | Audio | Chat + Audio player |
| **STT** | Audio | Text | Streaming transcription |

## ScaffoldConfig

All app customization starts in `EdgeScaffold/App/ScaffoldConfig.swift`:

```swift
enum ScaffoldConfig {
    static let appName = "MyApp"
    static let appDescription = "AI-powered app"
    static let defaultSystemPrompt = "You are a helpful assistant."
    static let modelCategory: ModelCategory = .llm
    static let bundleModelName: String? = "Qwen3.5-4B-6bit"
}
```

## Build

```bash
xcodegen generate
open EdgeScaffold.xcodeproj
```

For real-device validation, use a Release build:

```bash
xcodebuild -project EdgeScaffold.xcodeproj \
  -scheme EdgeScaffold \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  SKIP_MODEL_COPY=1 \
  build
```

## Version Contract

`.min_runtime_version` specifies the minimum EdgeKit version this template requires. EdgeStudio reads this file during export and writes the same version into `project.yml`.

Current: **1.0.0-rc98**

## License

MIT - AtomGradient
