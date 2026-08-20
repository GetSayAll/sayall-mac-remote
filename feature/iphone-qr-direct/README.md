# iPhone 二维码局域网直连

## 目的与用户行为

当 iPhone 长时间无法通过 Bonjour 发现 Mac 时，Mac 可生成当前监听周期的一次性二维码，让 iPhone 优先尝试局域网直连。连接失败后仍由客户端回退原有自动发现。

## 本包职责与非目标

`SayAllMacRemoteCore` 负责生成邀请、限制候选地址、校验一次性邀请并维持旧客户端兼容。不负责二维码界面、相机扫描、iOS 地址重试、宿主授权文案或按键执行。本次契约修复不改变 Bonjour、Watch、Web、音频或 HID 行为。

## 地址与隐私边界

- 邀请最多包含 8 个局域网地址，与 iOS 解析上限一致。
- 优先保留私有/共享 IPv4 与 IPv6 ULA，再考虑 link-local 地址。
- 日志只记录候选数量，不记录具体地址、端口、二维码或邀请凭据。

## 涉及文件

- `Sources/SayAllMacRemoteCore/PhoneRemoteInvitation.swift`
- `Tests/SayAllMacRemoteCoreTests/PhoneRemoteServerTests.swift`
- `Testing/iPhoneQRInvitationHostLimit.md`
- `Bugs/2026-08-20-qr-direct-host-count-contract.md`

## 状态与验证

地址数量和优先级已有自动化回归。真实多网卡 Mac、二维码扫码、首地址失败后的重试、Bonjour 回退、Watch 兼容及完整语音流程仍需真机验收。
