# MHub for iOS

[MHub](https://github.com/jizizr/mhub) 的 iOS 客户端（SwiftUI，iOS 26+）。连接自托管的 MHub 服务端，操作逻辑与网页版一致，界面使用液态玻璃、底栏附件迷你播放器、缩放转场等系统特性，参照 Apple Music 的设计语言。Android 版见 [mhub-android](https://github.com/jizizr/mhub-android)。

## 安装 Beta

在 [Releases](https://github.com/jizizr/mhub-ios/releases) 下载 `MHub-<版本>-unsigned.ipa`，用 AltStore、SideStore、Sideloadly 或 TrollStore 以自己的 Apple ID 签名安装。首次启动填写服务端地址。

## 目录

```text
project.yml          XcodeGen 工程描述（.xcodeproj 不入库）
MHubKit/             纯逻辑 Swift 包：模型、接口、队列、歌词（不依赖 UI）
MHub/                SwiftUI 应用：界面、AVQueuePlayer 播放、边播边缓存
contract/            接口样例与队列、逐字估算用例 —— 与 mhub-android 完全相同
docs/                两端共同的交互规范与接口契约 —— 与 mhub-android 完全相同
```

## 构建与测试

需要 Xcode 26 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
swift test --package-path MHubKit     # 逻辑与共享用例
xcodegen generate                     # 生成 MHub.xcodeproj
xcodebuild -project MHub.xcodeproj -scheme MHub -destination 'generic/platform=iOS Simulator' build
```

模拟器自动化测试播放时以 `MHUB_MUTE=1` 启动保持静音（`SIMCTL_CHILD_MHUB_MUTE=1 xcrun simctl launch …`）；`-server <地址>` 启动参数可覆盖已保存的服务端地址。

## 发布

推送 `v*` 标签（如 `v0.1.0-beta.2`）触发 `release.yml`：跑单测、无签名归档、打包 IPA 并创建 GitHub Release（带后缀的标签为预发布）。

## 与 Android 保持一致

- `contract/` 与 `docs/` 两个仓库必须逐字节相同，CI 的 `shared` 任务会比对 mhub-android。改动时两边同样提交。
- 改交互或文案先改 `docs/design.md`；改队列行为先在 `contract/queue-cases.json` 加用例；改接口字段先改 `contract/fixtures` 和 `docs/api-contract.md`。iOS `MHubKit` 与 Android `core` 都要通过。
- 原生端不传 `streaming_mode`；服务端返回可选的 `stream_length` 时可边下边播，老服务端则等任务完成后播放。

## 社区

感谢 [LINUX DO](https://linux.do/) 社区。

## 许可

AGPL-3.0-only。通过各平台获取的音乐、封面和歌词，版权归权利人所有。
