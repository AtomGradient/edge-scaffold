# EdgeScaffold

Reference iOS app scaffold for EdgeKit, EdgeEngine, EdgeHalo, EdgeMesh, and
Neural Imprint.

EdgeScaffold is both a public reference app and the template that Edge Studio
uses when it exports a buildable iOS app. It is designed to be easy for a
developer or an agent to continue from: the important entry points are named,
the generated files are separated from app code, and the runtime dependencies
come from public Swift Package Manager URLs.

## What This Repo Is

EdgeScaffold is an app template, not a shared library. Production apps should
copy, export, or fork it as an app surface, while shared runtime behavior stays
in the foundation packages:

```text
edge-scaffold / exported apps / dogfood-app
          \              /
            edge-kit
          /          \
 edge-engine      edge-halo binary
```

Use this repo to inspect the standard app-side wiring for:

- Streaming LLM, VLM, TTS, and STT chat surfaces.
- Four-tier model loading: local cache, app bundle, ODR, remote fallback.
- EdgeKit inference, model, mesh, data, and session modules.
- EdgeHalo binary integration and Neural Imprint restore hooks.
- EdgeData classification, facts, tool registry, and tool schema snapshots.
- EdgeMesh pairing and artifact backflow to Edge Studio.
- Scaffold smoke surfaces for feedback, corrections, and self-learning flows.

## Start Here

```bash
git clone https://github.com/AtomGradient/edge-scaffold.git
cd edge-scaffold
xcodegen generate
open EdgeScaffold.xcodeproj
```

In Xcode:

1. Wait for Swift Package Manager to resolve dependencies.
2. Select a development team in Signing & Capabilities.
3. Build on a physical iOS device. Simulator is not supported for MLX runtime
   validation.

For a command-line build check:

```bash
xcodebuild -project EdgeScaffold.xcodeproj \
  -scheme EdgeScaffold \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  SKIP_MODEL_COPY=1 \
  build
```

## Project Map

```text
EdgeScaffold/
+-- App/
|   +-- EdgeScaffoldApp.swift
|   +-- AppDelegate.swift
|   +-- ScaffoldConfig.swift
+-- AI/
|   +-- AIManager.swift
|   +-- AIStateManager.swift
|   +-- EdgeDataBootstrap.swift
|   +-- MeshManager.swift
|   +-- PersonalizationManager.swift
|   +-- ScaffoldHaloRuntimeAdapter.swift
+-- Chat/
|   +-- DemoChatView.swift
|   +-- DemoChatView+LLM.swift
|   +-- DemoChatView+VLM.swift
|   +-- DemoChatView+TTS.swift
|   +-- DemoChatView+STT.swift
+-- Settings/
+-- Business/
+-- Onboarding/
+-- Sustainability/

Resources/
+-- SampleData/
+-- RPP/
+-- Assets.xcassets/

project.yml
edgescaffolding_model_config
.min_runtime_version
.scaffold_version
```

## Main Configuration

Start with `EdgeScaffold/App/ScaffoldConfig.swift`.

Common fields:

- `appName`: display name used by the app shell.
- `defaultSystemPrompt`: default assistant behavior.
- `modelID`: logical model identifier.
- `modelDisplayName`: user-facing model name.
- `bundleModelName`: bundled model folder name when the model is copied into
  the app bundle.
- `modelCategory`: `.llm`, `.vlm`, `.tts`, or `.asr`.
- `defaultSampleDomainID`: sample domain shown by the scaffold demo surfaces.
- RPP fields: model family, shape, target layer, and resource name when an
  A-library is present.

Edge Studio rewrites these fields during app export. If you edit the template
directly, keep the field names stable so generated apps remain patchable.

## Model Loading

`EdgeScaffold/AI/AIManager.swift` owns model loading.

The app tries these sources in order:

1. Local app cache.
2. Model folder copied into the app bundle by the build phase.
3. On-Demand Resources using the `model` asset tag.
4. Remote fallback when the app is configured to allow it.

For local development, `edgescaffolding_model_config` controls the build phase:

```bash
MODEL_NAME=Qwen3.5-9B-4bit
MODELS_SOURCE_DIR=/path/to/models
MODEL_COPY="true"
```

`SKIP_MODEL_COPY=1` is useful for CI and release build checks when the real
model is not available on the build machine.

## Dependencies

The template resolves foundation packages through Swift Package Manager:

- `edge-kit` from `https://github.com/AtomGradient/edge-kit.git`
- `edge-engine` through the EdgeKit package graph
- `edge-halo-binary` from `https://github.com/AtomGradient/edge-halo-binary`

The EdgeHalo source repository is private. The public app template consumes the
binary package.

`.min_runtime_version` defines the minimum EdgeKit version required by this
template. Edge Studio reads it during export and writes the exact version into
the generated `project.yml`.

Current minimum EdgeKit version: `1.0.0-rc98`.

## Neural Imprint And RPP

The public scaffold can run without bundled RPP A-library assets. In that mode,
RPP-specific configuration remains empty and the app keeps those flows
fail-closed.

When an app needs model-matched RPP assets, Edge Studio or an authorized build
pipeline should place the manifest and referenced artifacts under
`Resources/RPP` before export.

The canonical Neural Imprint sample is documented in:

- [docs/neural-imprint-canonical-sample.md](docs/neural-imprint-canonical-sample.md)

The short integration path:

1. Configure app and model values in `ScaffoldConfig.swift`.
2. Register app schemas and tools from `EdgeDataBootstrap.swift`.
3. Replace sample data with real classified facts.
4. Generate or provide model-matched A-library assets when RPP flows are needed.
5. Restore Neural Imprint artifacts after model load.
6. Use EdgeMesh to exchange receipts and artifacts with Edge Studio.

## Common Customizations

- Change the first screen: edit `EdgeScaffold/Business/HomeView.swift`.
- Change chat behavior: edit `EdgeScaffold/Chat/DemoChatView*.swift`.
- Change model loading: edit `EdgeScaffold/AI/AIManager.swift`.
- Change sample domains: edit `Resources/SampleData` and the
  `ScaffoldSampleDomain` helpers.
- Change app settings: edit files under `EdgeScaffold/Settings`.
- Change package versions: update `.min_runtime_version` and `project.yml`
  together, then run a clean SPM resolve.

## Agent Notes

When using an AI coding agent on this repo, give it this order of operations:

1. Read `README.md`, `project.yml`, and `EdgeScaffold/App/ScaffoldConfig.swift`.
2. For model behavior, read `EdgeScaffold/AI/AIManager.swift` and
   `EdgeScaffold/Chat/DemoChatView+LLM.swift`.
3. For personalization, read `EdgeScaffold/AI/PersonalizationManager.swift`,
   `ScaffoldHaloRuntimeAdapter.swift`, and the Neural Imprint sample doc.
4. Do not edit generated Xcode project files first. Update `project.yml`, then
   run `xcodegen generate`.
5. Do not commit local DerivedData, `.build`, SPM caches, copied model weights,
   or generated archives.
6. After changes, run a build check with `SKIP_MODEL_COPY=1`.

## Troubleshooting

SPM cache looks stale:

```bash
rm -rf .build
rm -rf ~/Library/Developer/Xcode/DerivedData
xcodebuild -resolvePackageDependencies -project EdgeScaffold.xcodeproj
```

`xcodegen` is missing:

```bash
brew install xcodegen
xcodegen generate
```

Signing fails:

- Select a team in Xcode.
- Confirm the bundle identifier is unique.
- Build on a physical device.

Model is not copied:

- Check `edgescaffolding_model_config`.
- Confirm `MODEL_COPY="true"` for Debug builds.
- Confirm `MODELS_SOURCE_DIR/MODEL_NAME` exists.
- For CI, set `SKIP_MODEL_COPY=1`.

## License

MIT - AtomGradient
