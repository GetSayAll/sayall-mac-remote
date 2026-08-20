# 二维码直连候选地址超过 iOS 上限

- 日期：2026-08-20
- 状态：已修复，待真实多网卡与 iPhone 验收
- 影响范围：Mac 生成的 iPhone 二维码直连邀请；不修改 Bonjour、Watch 或 Web 连接路径

## 复现

iOS `DirectConnectionInvitation` 的协议上限为 8 个 `host`。修复前，Mac `PhoneRemoteInvitation.make` 会原样保留所有候选地址；使用 10 个合规局域网地址生成邀请时，测试观察到 `invitation.hosts.count == 10`。这样的 URL 会被 iOS 整体判为 `invalidLink`，而不是逐个尝试候选地址。

新增回归测试在修复前失败：`XCTAssertLessThanOrEqual` 实际值为 10、上限为 8，同时两个低优先级链路本地地址占据了候选列表前部。

## 日志检查

Mac 发布邀请时只记录 `PHONE REMOTE invitation_ready hosts=<数量>`，不记录 IP、端口、二维码、监听 ID、邀请 ID 或令牌。因此现有日志只能确认候选数量，不能从历史日志还原具体地址；本次没有扩大日志内容。

## 根因

Mac 与 iOS 分别实现二维码邀请契约。iOS 明确设置 `maximumHostCount = 8`，Mac 生成端此前没有相同上限，也没有在多网卡地址过多时优先保留更可达的私有 IPv4/IPv6 ULA 地址。

## 修复

- Mac 邀请模型增加与客户端一致的 8 地址上限。
- 所有邀请构造统一过滤非局域网地址、去重、按可达性排序并截断。
- 优先级为：私有/共享 IPv4、IPv6 ULA、IPv4 link-local、IPv6 link-local；同级保持原始顺序。

## 自动化验证

回归测试使用 10 个局域网候选地址，确认最终只保留 8 个，并在容量不足时优先舍弃 link-local 地址。运行：

```sh
swift test
```

## 验证边界

自动化证明生成模型不再输出超过 8 个地址，并验证候选排序规则。尚未在同时连接 Wi-Fi、网线、桥接网络和 VPN 的真实 Mac 上确认实际接口枚举，也未用真实 iPhone 扫描最终二维码、逐个尝试地址并完成授权、按键和语音流程。
