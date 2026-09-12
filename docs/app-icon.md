# 随心唱 App 图标

暖红色背景与米白色心形麦克风，延续 `StudioTheme` 的暖红与米白配色。

- 生成方式：内置 image_gen 工具。
- 安装资源：`VocalSeparator/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`。
- 资源为 1024 × 1024、不带透明通道的 RGB PNG，保留完整方形背景，由 iOS 应用圆角遮罩。
- `project.yml` 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 指向 `AppIcon`，Debug 与 Release 共用；Xcode 由通用 iOS 图标生成各使用尺寸。
- 更新后重新构建并安装到 iPhone，主屏幕名称仍为“随心唱”。重新生成工程时使用 `xcodegen generate --spec project.yml`，图标设置会保留。

## 验证记录（2026-09-12）

- 源资源检查 6/6 通过：PNG 格式、1024 × 1024、8-bit RGB 无透明通道、通用 iOS 声明、XcodeGen 设置、Debug/Release 工程设置。
- iPhone 17 Pro / iOS 26.5 模拟器构建和安装成功；主屏幕实际显示暖红色心形麦克风，名称为“随心唱”。
- `BundledModelContractTests` 实际执行 2 项，2 通过、0 失败、0 跳过，已核对 `.xcresult`。
- `generic/platform=iOS` 的 Release 构建成功（`CODE_SIGNING_ALLOWED=NO`）；本次未执行真机签名安装。
- 模拟器与 iPhone Release 产物各 6/6 项图标检查通过：显示名称、主图标名、主屏幕图标引用、生成的 PNG、`Assets.car`、其中的 1024 像素不透明 AppIcon。

## 生成提示词

```text
Use case: logo-brand
Asset type: Production iOS home screen app icon, square 1024 x 1024 artwork, for a local karaoke and vocal-separation app named 随心唱 (Sing Freely). This is the final icon artwork, not a mockup.
Primary request: An exceptionally clean, distinctive, friendly premium karaoke app icon. One large sculptural ivory handheld singing microphone, tilted slightly to the upper right, with a softly rounded heart-shaped microphone head. Three broad, elegant curved grille openings in the heart head make the microphone immediately recognizable. A short ivory microphone handle underneath. The heart and microphone read as a single bold, coherent symbol about singing from the heart.
Scene/backdrop: Full-bleed rich warm vermilion-red background with a very subtle tonal glow; every corner fully filled.
Color palette: Match the existing app UI's warm brick red (#C73B30), warm ivory (#F7F5F0). Restrained richer red shading for depth.
Style/medium: Refined modern app-icon design, precise smooth contours, gentle satin ceramic dimensionality with subtle highlights and a soft close shadow. Minimal, memorable, strong silhouette readable at 40 pixels. Mostly clean graphic form, not photorealism.
Composition/framing: Single centered generously sized heart microphone occupying around 65 percent of the canvas, balanced clear space around it. Square front-facing artwork.
Text: None.
Constraints: Opaque RGB artwork. Background must extend all the way to all four square corners. Do not draw a rounded square tile or an outside frame; iOS applies its own corner mask. No lettering, no wordmarks, no watermarks, no extra music notes, no sparkles, no tiny details, no border, no inset frame, no phone, no icon grid.
```
