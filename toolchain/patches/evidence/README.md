# 发布证据目录（design D14）

三类证据，**绑定补丁集 sha256**（不是绑定版本号——意图说的是"这个 sha"，
证据验的是"这个 sha"，三者对不上就是无效证据）：

| 文件 | 谁产出 | 何时必需 | 进仓树？ |
|---|---|---|---|
| `fnos-<ver>.intent.json` | 人工 | **仅修正路径** | ✅ 进仓（随真源同步，公开） |
| `fnos-<ver>.behavior.json` | 人工（活容器上跑探针） | **仅修正路径** | ✅ 进仓（公开，已脱敏） |
| `fnos-<ver>.evidence.json` | CI 校验 job | **所有路径** | ❌ 只作 Release 资产 |

- **字节级证据（evidence）不进仓**：它由公开 CI 的校验 job 产出；提交回仓会触发
  "产证据 → 搬运 → 仓变动 → 再校验 → 再产证据"的自触发循环。它作为 Release 资产发布，
  用户可自行核验。
- **行为级证据（behavior）进仓但脱敏**：宿主地址、容器标识、账号不出现在公开形态里。
- **意图（intent）是修正路径的正常入口**：首发不需要（补丁集进仓本身就是声明）。

schema 校验：`python3 toolchain/evidence.py validate <file> <kind> <version> <sha256>`
