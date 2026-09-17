# 一次性解锁导出

商品 ID：`SingFreelyPro`。商品类型必须是 **Non-Consumable（非消耗型）**。
购买一次解锁后续导出，没有订阅、自动续费或按次收费。正式售价只从 StoreKit `Product.displayPrice` 读取。

## 功能范围

- 歌曲库／伴奏库菜单：伴奏、人声导出。
- 歌曲详情：伴奏、人声、原曲导出。
- 我的演唱菜单、演唱回放：已保存混音、原始录音导出。
- 转写结果：分享文字、复制文字；未解锁时不开放系统文本选择的复制／分享菜单。
- 歌曲详情的内嵌歌词：未解锁时关闭系统文本选择的复制／分享菜单。
- WAV、MP3、AAC、ALAC 使用同一权限，不因格式不同而绕过购买。
- 导入、分离、转写、播放、录音和 App 内保存仍可正常使用。
- “开源许可证”内的 LGPL 对应源码与构建说明属于许可证交付材料，始终可免费获取，不属于付费的用户内容导出。

所有音频导出入口继续使用 `AudioExportSheet`，由 `ExportAccessGate` 在展示受保护内容前检查权限。
购买／恢复成功后，同一页面继续原来的导出请求，无需再次选择文件。
`AuthorizedAudioExporter` 在转码前和分享前再次检查权限。取消会取消导出并清理临时文件；转码期间失去权限会删除输出。
转写分享也使用同一个 gate，复制前再次检查权限。

`ExportPurchaseController` 只接受匹配商品 ID、非消耗型、通过 StoreKit 验证且未撤销的交易。
App 启动、回到前台和每次导出都会读取 `Transaction.currentEntitlements`；启动时监听 `Transaction.updates`。
本地不会用 UserDefaults 或自行保存的布尔值代替购买凭证。StoreKit 可提供已保存的验证交易；离线使用不依赖商品价格加载成功。
待批准交易不解锁，批准后通过交易更新生效。退款／撤销后重新锁定；已发送到 App 外部的文件无法追回。
恢复按钮才调用 `AppStore.sync()`，避免普通启动或导出主动弹出账户验证。

购买页面提供本地价格、一次性解锁说明、恢复购买、可关闭按钮，以及与设置共享的可打开链接：

| 语言 | 隐私政策 | 使用条款 |
| --- | --- | --- |
| 简体中文 | https://easykaraoke.xyz/privacy/ | https://easykaraoke.xyz/terms/ |
| 英文与其他语言回退 | https://easykaraoke.xyz/en/privacy/ | https://easykaraoke.xyz/en/terms/ |

## 本地测试

`Config/ExportLifetime.storekit` 只有一个非消耗型商品，**0.99 是本地测试价格，不是正式售价决定**。
Xcode 选择 `VocalSeparator-StoreKit` scheme 可使用该配置手动测试购买。
普通 `VocalSeparator` scheme 当前在 Xcode 中选择了 `Sing Freely.storekit`，其中 `SingFreelyPro` 的测试价格为 3.99。
两份配置的商品 ID 均与 `ExportPurchaseController.productID` 一致；不同测试价格不影响权限判断。
`Config/ExportLifetime.storekit` 作为测试 bundle 的资源供 `SKTestSession` 使用，不打进正式 App 资源。

- `ExportPurchaseTests`：权限过滤、购买成功、取消、待批准、验证失败、购买失败、恢复、撤销、并发操作及各格式导出拦截／临时文件清理。
- `StoreKitExportTests`：用真实 StoreKit 测试环境执行购买、重新创建控制器、恢复、退款和 Ask to Buy 批准。
- `ExportPurchaseViewTests`：购买前不创建分享内容、解锁后显示、撤销后移除，以及紧凑屏幕／大字体／商品不可用的购买页截图。
- `AudioExportTests` 和 `LocalizationTests`：回归导出格式及中英文本。

## App Store Connect 配置与验收

1. 在实际 App 记录中创建上述 ID 的非消耗型内购。如果正式商品 ID 不同，同步修改控制器常量与 `.storekit` 配置。
2. 设置售价、销售地区、中英文名称／说明、审核截图，并完成 Apple 要求的协议、税务和银行配置。
3. 确认正式 Bundle ID 与签名 App、App Store Connect 记录一致；本项目主应用使用 `xyz.easykaraoke.singfreely`。
4. 首次内购随支持该功能的 App 版本一起提交审核，审核说明写明从“设置 → 永久导出”或任意导出按钮进入购买页面。
5. 真机 Sandbox／TestFlight 必须关闭本地 StoreKit 配置，验证购买、取消、恢复、重新安装、离线已购、待批准、退款／撤销，以及实际分享目标。

本地测试不创建 App Store Connect 商品，也不证明 Sandbox／TestFlight／正式商店交易已通过。

## 2026-09-17 验证记录

- iPhone 17 Pro / iOS 26.5 Simulator：英文 43/43、中文 43/43，均 0 失败、0 跳过。
  覆盖 15 项购买控制器／权限测试、4 项购买页／gate 测试、17 项音频导出测试、7 项本地化测试。
- 已人工查看中英文紧凑屏幕与大字体截图；普通字号下购买、恢复、隐私政策和使用条款均可见，大字体使用可滚动布局。
- 四个隐私政策／条款 URL 均通过 HTTPS 跳转到 www 域名并返回 HTTP 200。
- generic iPhone Release 未签名构建成功。最终 App 中没有 `.storekit` 测试配置，保留已有隐私清单和中英文本。
- `git diff --check`、StoreKit JSON 校验和 LAME 对应源码一致性检查通过。
- **StoreKit 交易集成测试未通过**：3 项测试均失败，环境返回 `SKInternalErrorDomain Code=3`，
  直接调用 `SKTestSession.buyProduct` 返回 `notEntitled`，商品列表为空。更换专用 StoreKit scheme、
  使用模拟器临时签名后仍可复现。曾误入 Apple 账户登录弹窗，已取消；未输入账户或执行实际付款。
  因此购买、恢复、待批准及退款的自动化权限逻辑已验证，但真实 StoreKit 交易桥接仍需在可用的
  Xcode StoreKit 测试环境和真机 Sandbox／TestFlight 重新验收，不能将本地 mock 通过当作交易通过。

本次证据在 `/private/tmp/vocal-iap-20260917/`：`en-final.xcresult`、`zh-final.xcresult`、
`storekit-final.xcresult`、`release.log` 以及 `en-final-attachments/`、`zh-final-attachments/`。

## 2026-09-17 商品 ID 对齐验证

- 控制器与 `Config/ExportLifetime.storekit` 已统一使用 `SingFreelyPro`，与 `Sing Freely.storekit` 一致。
- 从 Xcode 的 `VocalSeparator` scheme 正常 Run 后，iPhone 17 Pro / iOS 26.5 Simulator
  购买页实际显示 `Unlock Lifetime Export — $3.99`；本次未点击购买。
- `ExportPurchaseTests` 实际执行 15/15 通过，0 失败、0 跳过；结果位于
  `/private/tmp/vocal-product-id-20260917/unit-tests.xcresult`。
- `StoreKitExportTests` 在初始化 `SKTestSession` 时仍返回 `SKInternalErrorDomain Code=3`，
  首个用例长时间无进展后已中断，未完成交易集成验证。日志位于
  `/private/tmp/vocal-product-id-20260917/purchase-tests.log`。
- 两份 StoreKit JSON、两条 Scheme 配置路径及 `git diff --check` 检查通过。

实现依据：[Apple 交易验证与权益说明](https://developer.apple.com/documentation/storekit/transaction)、
[恢复购买](https://developer.apple.com/documentation/storekit/appstore/sync())、
[StoreKit Test](https://developer.apple.com/documentation/storekittest)。
