# iPhone 二维码邀请地址上限测试

## 适用范围

- `sayall-mac-remote` 分支：`codex/iphone-qr-direct`
- 验证 Mac 生成端与 iOS 最多 8 个地址的契约一致性。

## 自动化用例

运行 `swift test`。`PhoneRemoteServerTests.testGeneratedInvitationRespectsClientHostLimitAndKeepsPreferredLocalAddresses` 必须确认：

1. 输入超过 8 个合规局域网地址时，邀请最多包含 8 个 `host`。
2. 私有/共享 IPv4 与 IPv6 ULA 优先于 IPv4/IPv6 link-local。
3. 同一优先级内保持输入顺序。

任一断言失败即判定不能集成或发布。

## 真实环境用例

1. Mac 同时连接 Wi-Fi、网线、桥接网络和 VPN，打开 iPhone 连接二维码。
2. 检查日志仅显示候选数量，不出现 IP、端口或邀请凭据。
3. 使用真实 iPhone 扫码，确认二维码不会提示无效。
4. 让首个候选不可达，确认 iPhone 会继续尝试后续候选；完成授权、按键和一次语音开始/音频/停止。
5. 回归 Watch TCP/BLE 和未扫码的 Bonjour 连接。

预期：候选不超过 8 个，至少一个真实局域网地址可连接；全部地址不可达时回退 Bonjour。二维码无效、首个地址失败即停止、日志泄露地址或 Watch/Bonjour 回归均判定失败。

## 日志收集与边界

记录测试时间并收集 Mac 宿主 `runtime.log` 和 iOS 诊断日志。允许记录候选数量、候选序号、超时与 fallback；不得记录 IP、端口、二维码内容、监听/邀请 ID、令牌、确认码、身份指纹、密钥或音频。

自动化不证明真实多网卡枚举、二维码扫描、局域网可达性、相机权限、Watch 射频或语音链路已通过；这些项目必须真机验收。
