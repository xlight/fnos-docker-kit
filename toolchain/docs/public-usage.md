# fnOS 容器化公开工具链 — 使用文档

本仓库是从飞牛 fnOS 官方 ISO 构建容器镜像所需的最小公开集：
ISO 提取引擎、补丁施加器、版本化补丁集、成像工具、编排器、部署脚本与自测。
配合你自己从官网下载的官方 ISO 使用；仓库内不含任何 fnOS 二进制。

## 0. 准备

- 64 位 Linux（Debian 12 / Ubuntu 22.04+），有 sudo/root。
- Python 3.10+，`pip install -r requirements.txt`（若有）。
- 构建需要约 30GB 可用磁盘（ISO + 解包 rootfs + 镜像）。
- 从飞牛官网下载对应版本的官方 ISO（记下其版本号，如 `V1.2.0701`）。

## 1. 构建镜像

```bash
# 1) 解包出厂 rootfs（需要 root；<destdir> 为你自选的空目录）
sudo python3 fnos_iso.py extract <官方ISO> <destdir>

# 2) 打补丁（补丁集版本必须与 ISO 版本一致，否则拒绝执行）
sudo python3 fnos_patch.py apply --rootfs <destdir>

# 3) 生成镜像并自检
sudo python3 fnos_image.py mkraw <destdir> ./image.raw 12 --fs ext4
sudo python3 fnos_image.py check ./image.raw --patchset patches/fnos-<ver>.json
```

## 2. 部署

LXC（需 PVE 宿主）：

```bash
sudo bash fnos_deploy.sh install <ctid> --image ./image.raw --storage <你的PVE存储池>
```

Docker（任意 Docker 宿主，见 `fnos_docker_compose.yml` 注释）：

```bash
sudo bash ../scripts/fnos_deploy_docker.sh install <name> --port <宿主端口>
```

专属存储（可选）：用 `stor-manage.sh`（LXC）或 `stor-manage-docker.sh`（Docker）
在宿主预建存储栈，再透传给容器。**永远不要把宿主系统盘或别人在用的盘透传进容器。**

## 3. 自测

```bash
bash tests/selftest.sh        # 补丁引擎（无需容器）
bash tests/pipeline_test.sh   # 编排器（无需容器）
```

缺 fixture 时测试会明确告诉你先跑 `fnos_iso.py extract` 生成，而不是报含糊的失败。

## 4. 边界（必读）

- 补丁集绑定 fnOS 版本：`patches/fnos-<ver>.json` 只适用于同版本 ISO；换版本等新补丁集 Release，不要强行混用（施加器会拒绝）。
- 容器内 fnOS 的"存储空间"需要专属块设备（见上）；普通目录绑定只能被"看到"，不能当安装卷。
- 容器内个别服务（如 `trim_trashbind`）会因缺专用内核设备而重启循环：预期内，不影响文件/应用。
- Web UI 的存储"未激活"标签在容器下是已知显示问题：功能正常即可忽略。

## 5. 来源声明、下架承诺与发布渠道对齐（合规）

- **来源声明**：本仓库不含任何 fnOS 二进制；所有镜像均由使用者从飞牛官方渠道取得的材料构建。自动发布的 Docker 镜像同样如此：ISO 分支衍生自官方 ISO，仅叠加容器兼容补丁；`-ota` 分支以已发布的公开镜像为底座，叠加官方 OTA `.deb` 包组的文件内容（逐包 sha256 与官方清单比对），不等官方 ISO 上架。本项目与飞牛官方无关，不代表官方立场。
- **渠道对齐**：本仓库的 GitHub Release 只挂补丁集等文本资产，**不发布镜像产物**（规避 2 GiB 资产上限与版权风险）；容器镜像只走 Docker Hub（`xlight/fnos-dockermode` 的版本 tag / `latest`）。两者渠道不同，立场一致：不分发官方二进制，只分发构建方法与补丁。
- **下架响应承诺**：如权利方提出异议，维护者将在收到通知后 72 小时内下架相关镜像 tag 并在 Issue 中公示；联系方式见仓库 Profile / Issue。

## 6. 发布流程（四个单元：观察 / 搬运 / 发布 / 构建）

| 单元 | 位置 | 触发 | 产出 |
|---|---|---|---|
| **观察** | 公开仓 `public-watch.yml` | 每天定时 | 双通道检测 + 一条持续可见的版本状态 Issue |
| **搬运** | **私有真源** workflow | 每次 push 真源 | 公开仓 main（内容 + 就绪索引，一次推送） |
| **发布** | 公开仓 `public-release.yml` | 公开仓 main 推送 / tag 推送 / 手工 dispatch | GitHub Release 的补丁集 + 就绪索引 + **发布证据** |
| **构建** | 公开仓 `public-ci.yml` | **显式**（`publish.sh --image <ver>` 或手工 dispatch） | Docker Hub 镜像 tag |

- **发布按分级触发**（design D13）：
  - **首发**（目标发布 tag 尚不存在）：CI 在目标版本的出厂件上逐站验哈希（官方 ISO = 强证据；
    无 ISO 时用底座镜像 + **全量** OTA 包 = 中证据），字节级证据通过即自动发布 `v<ver>`；
  - **修正**（tag 已存在）：还必须有人工产出的「意图 + 行为验收」两份证据，且都绑定本次补丁集的
    `sha256`，才发布 `v<ver>-r<N+1>`（修订号由既有 tag 推导）。
  - 判据是**目标发布 tag 是否已存在**——不是就绪索引条目（索引会被本次同步改写，用它判会把
    每次首发都误判成修正）。
- **发布证据公开可核验**：字节级证据（校验环境来源、逐站命中数、出厂指纹、交叉核对结论）作为
  Release 资产发布；行为级证据与意图进仓（已脱敏：宿主地址、容器标识、账号不外泄）。
  字节级证据**不进仓树**——提交回仓会触发"产证据 → 搬运 → 仓变动 → 再校验"的自触发循环。
- **观察单元只发现、不构建**：每天一次定时任务走双通道——(a) 官网下载页内嵌版本信息（版本号 + 官方 hash）；(b) OTA 版本清单（匿名查询，`trim.version` 为准）。两通道 state 各记各的（`state/page_ver`、`state/ota_ver`，CI 提交），互不阻塞，且各自在**自己的成功点**写入。下载直链有时效，每次构建时现场获取，不硬编码。
- **状态即 Issue**：检出新版后，观察单元按（版本, 通道）维护**一条** Issue——`待 rebase: 1.2.1000 (ISO)`（公开仓还没有该版本补丁集）或 `可构建: 1.2.1000 (ISO)`（补丁集已就绪、镜像还没发）。状态不变就不动它（不做每日评论）；被误关会自动重开；补丁集发布且镜像 tag 出现后自动关闭。**不会**每天为同一件事刷一条新 Issue。
- **构建必须显式声明**：检测到新版**不会**自动构建。要出镜像，显式执行 `bash toolchain/publish.sh --patchset <ver> --image <ver>`，或手工 `gh workflow run public-ci.yml -f version=<ver>`。因此新版本上线速度由人决定，代价是"缺补丁集"这件事变成一条长期开着的可见待办，而不是一堆重复告警。
- **已知脆弱点**：官网改版（页面结构/字段变化）会导致检测失败——此时流水线显式失败并告警，不会静默当成"无新版"；直链下载被拦截时开 Issue，需人工提供 ISO 后手动触发构建；OTA 未文档化 endpoint 变更只影响 deb 分支，不连累 ISO 分支。Docker Hub 查询失败时**保守处理**：既不判"已发布"（免得误关 Issue），也不判"未发布"（免得重复构建覆盖 `latest`）。
- **就绪索引与覆盖度矩阵**：`toolchain/patches/index.json` 是消费权威副本（容器与 proxy 都读它），Release 里的同名资产是归档快照。索引含三段：`versions`（每个补丁集一条，带 `sha256` 与 `source_commit`）、`samples`（目标版本的二进制指纹样本，标注信任级别与 `state`）、`coverage`（补丁集 × 目标版本的覆盖度，纯哈希运算：`目标版本文件哈希 ∈ {orig, patched}` 即覆盖）。消费侧据此回答"这个补丁集对我这个版本能用多少"，部分覆盖时状态行会点名未覆盖的文件。**旧索引（无矩阵）按"精确版本命中"解释，行为不变。**
- **tag 语义**：`1.2.1000` 式版本 tag 对应 fnOS 版本，一次构建不变；`latest` 恒指向最近一次 **ISO 全量**构建成功的版本；构建失败绝不碰任何 tag。
- **发布 tag 不可变**：补丁集发布用 `publish.sh` 声明，已存在且内容合规 → 幂等跳过；已存在但内容不符 → 报错拒绝（修正内容要用新的发布修订号，如 `v1.2.1010-r2`，fnOS 版本锚不变）。
- **补丁失效按阶段分类**：新版上补丁未全命中时不推送镜像，CI 失败并开 Issue，标题按**失败阶段**措辞（`补丁失配` / `补丁施加失败` / `镜像生成失败` / `推送失败` / `基础设施受阻`），正文含 per-site 清单或日志尾部。补丁检查全绿却失败在后续阶段时，**不会**被误报成"补丁失配"。

## 6b. `-ota` 镜像语义（deb 分支）

- **是什么**：OTA 领先下载页约一版时，用**上版公开镜像为底座 + 官方 `.deb` 包组文件覆盖**提前构建的同版本镜像，tag 为 `X-ota`（如 `1.2.0800-ota`）。构建法见 workflow `build` job 的 deb 头步骤；门禁与推送尾巴和 ISO 分支共用同一份实现。
- **tag 隔离**：`-ota` 与同数字的 ISO 版内容不同（构建法与补丁 review 状态不同），tag 名隔离；deb 版**永不推进 `latest`**（手动触发默认也不推，需显式 `promote_latest` 且仅 ISO 分支有效）。
- **底座规则**：底座 = Hub 上数字版本严格低于目标版本的最高 tag（数字相同优先无 `-ota` 后缀；绝不用 `latest`）；export 后按清单清理运行时残留（machine-id、hostname、logs、`/.dockerenv`），machine-id 由推送步重建。无底座时显式失败，等 ISO 版先出。
- **dpkg 撒谎声明**：deb 头跳过 dpkg 库与 pre/post 脚本（构建期无 systemd/postgres/grub），故 `-ota` 镜像内 `dpkg -l` 显示的仍是底座版本（如底座库 0701 而文件已是 0800）——**不可信**；基线一律以文件 hash 为准。以 `-ota` 镜像为底座的下一版同样如此。
- **版本戳**：`.deb` 不含 `usr/trim/etc/version`，由构建手工写入目标版本（补丁施加器的版本锚点必需，无此文件拒绝打补丁）。

## 7. 社区协作规则（CONTRIBUTING）

- **PR 只收本公开仓**：文档、workflow、构建逻辑的改进欢迎直接提 PR。
- **反向 port**：公开仓是由私有真源生成的；合入的 PR 会由维护者反向 port 回私有仓，下次同步时以真源为准（直接改公开生成物可能被覆盖）。
- **Issue 内容规则**：只放结果型信息（版本、命令、失败报告、日志片段）；不要放推导方法与内部分析过程。
