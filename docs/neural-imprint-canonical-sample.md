# Neural Imprint Canonical Sample

This document maps the Neural Imprint sample in EdgeScaffold to the foundation modules a production app should use.

EdgeScaffold is a reference app and export template. It is not a package for other apps to import. If a capability becomes generally useful, move it to `edge-kit`, `edge-halo`, or `edge-engine`; keep only app-specific wiring and UI in EdgeScaffold.

## Boundary

```
edge-scaffold / other apps / dogfood-app
       /              \
  edge-kit          edge-halo
       \              /
          edge-engine
```

- `edge-engine`: native inference, cache capture/restore, safetensors primitives.
- `edge-kit`: Swift app SDK, EdgeData, ToolRegistry, EdgeMesh, EdgeUI, ToolChatLoop, Neural Imprint restore API.
- `edge-halo`: self-learning orchestration, RPP runner ownership, Neural Imprint capsule mapping and compatibility policy.
- `edge-scaffold`: reference app wiring and developer-facing sample UI.
- `dogfood-app`: business validation app. It must not depend on EdgeScaffold.

## Current Sample Surfaces

| Surface | File | What it demonstrates |
|---|---|---|
| App and model config | `EdgeScaffold/App/ScaffoldConfig.swift` | Model family, model category, generation defaults, bundle/ODR settings |
| Model loading | `EdgeScaffold/AI/AIManager.swift` | Documents -> cache -> bundle -> ODR -> remote load order |
| Model install path diagnostic | `EdgeScaffold/AI/AIManager.swift` + `EdgeScaffold/Settings/AIEngineSection.swift` | Warns when model files are pushed to `Documents/` instead of `Documents/<ScaffoldConfig.modelID>/` |
| Neural Imprint restore | `EdgeScaffold/AI/AIManager.swift` | Auto-restore from `Documents/neural_imprint` after model load |
| Data bootstrap | `EdgeScaffold/AI/EdgeDataBootstrap.swift` | SQLite setup, EdgeData migrations, schema/tool registration |
| Tool sample | `EdgeScaffold/AI/ScaffoldTooling.swift` | Read-only ToolRegistry tool backed by classified facts |
| Tool schema snapshot | `EdgeScaffold/AI/ScaffoldHaloCapsulePolicy.swift` | Tool schema hash for Halo capsule compatibility |
| RPP sample data | `EdgeScaffold/AI/RPPDemoData.swift` | Built-in records for out-of-box RPP demo |
| Persona RPP input exporter sample | `EdgeScaffold/AI/RPPDemoData.swift` + `EdgeScaffold/AI/MeshManager.swift` | Convert app-owned records into `edgestudio.persona_rpp_input.v1` and upload over EdgeMesh |
| EdgeHalo runtime bridge | `EdgeScaffold/AI/ScaffoldHaloRuntimeAdapter.swift` | App-side bridge from EdgeKit LLM/VLM engines into EdgeHalo protocols |
| RPP A-library manifest | `Resources/RPP/rpp_a_library_manifest.json` | EdgeStudio-provided model-family to A-library artifact, target layer, and health report contract |
| RPP self-learning | `EdgeScaffold/AI/RPPSelfLearningManager.swift` | EdgeHalo profile analysis, hidden-state capture, RPP output dumps |
| RPP backflow | `EdgeScaffold/AI/MeshManager.swift` | Upload `rpp_last_run.json` and B-directions over EdgeMesh |
| Smoke UI | `EdgeScaffold/Settings/PersonaABTestView.swift` | Persona probes and control prompts |
| Developer hub | `EdgeScaffold/Settings/PersonalizationHubView.swift` | End-to-end pipeline status and entry points |

## Standard App Flow

1. Configure the model in `ScaffoldConfig`.

   `ScaffoldConfig.modelID` must match the directory pushed to `Documents/<modelID>/` during device testing. Do not alias a 9B model under a 4B directory name.

   The scaffold diagnoses misplaced model files at `Documents/` root and points developers back to `Documents/<ScaffoldConfig.modelID>/`. It intentionally does not delete or move files automatically; product apps may add their own repair policy if they own the deployment channel.

2. Register schemas and tools at startup.

   `EdgeDataBootstrap.setup()` opens `Documents/edge_data.sqlite`, runs EdgeData migrations, registers the scaffold demo schema, and calls `ScaffoldTooling.registerTools()`.

3. Replace demo data with product facts.

   The scaffold ships sample records so the pipeline is visible immediately. A production app should replace `RPPDemoData.loadData()` with a query over classified `EdgeData` facts and convert those facts to `RPPRawTransaction` or the app-specific RPP input type.

   For Mac-side RPP input upload, keep the same boundary: the app owns the facts query and business mapper, then passes generic `ScaffoldPersonaRPPInputSourceRecord` values to `ScaffoldPersonaRPPInputExporter.payload(...)`. The exported wire contract is `edgestudio.persona_rpp_input.v1`; app-specific sentence templates and field choices stay outside `edge-kit`.

4. Run RPP with the matching A-library.

   EdgeScaffold composes `edge-kit` and `edge-halo` in the app layer. `ScaffoldHaloRuntimeAdapter` exposes the loaded LLM/VLM engine as `HaloTextGenerator` and `HaloEngineSession`; `AIManager.runRPPProfileAnalysis(...)` calls EdgeHalo's canonical RPP surface. Public source does not commit A-library artifacts; EdgeStudio or an authorized build pipeline places `Resources/RPP/rpp_a_library_manifest.json` and the referenced `.safetensors` files during export. Other model sizes need an EdgeStudio-exported A-library with its own target layer and health report. The app must fail closed if hidden size, model family, layer count, or A-library metadata do not match the loaded model.

5. Generate or receive Neural Imprint.

   The app restores Neural Imprint from the first directory that contains both:

   ```
   neural_imprint.safetensors
   neural_imprint_metadata.json
   ```

   The preferred layout for manual testing is:

   ```
   Documents/neural_imprint/neural_imprint.safetensors
   Documents/neural_imprint/neural_imprint_metadata.json
   ```

6. Validate behavior.

   Load the model, confirm the Home screen shows `Neural Imprint active`, then run Neural Imprint Smoke. The app writes `Documents/neural_imprint_restore_status.json` for diagnostics.

7. Sync back to EdgeStudio.

   `MeshManager.uploadLatestRPPArtifactsToMac()` sends the RPP receipt and B-directions to the paired Mac. EdgeStudio owns host-side inspection, generation, and distribution workflows.

## Tooling Rule

The scaffold's read-only tool is only a developer sample. It demonstrates the shape of a ToolRegistry integration:

- tool metadata and JSON schema
- read-only permissions
- EdgeData-backed execution
- tool schema snapshot for capsule compatibility

Do not place route-boundary planned tool-call heuristics in the scaffold. The intended pattern is: tools are registered, their schema is available to the model or Neural Imprint generation pipeline, and the model chooses whether to call a tool.

## Release Validation Checklist

- `.min_runtime_version` matches the EdgeKit exact version in `project.yml`.
- `ScaffoldHaloCapsulePolicy.currentRuntimeVersion` reports `EdgeKitRuntime.version`.
- The model directory name exactly equals `ScaffoldConfig.modelID`.
- `Documents/neural_imprint` contains both artifact and metadata before restore smoke.
- RPP uses an A-library generated for the loaded model family and hidden size.
- Real-device builds are Release builds.
