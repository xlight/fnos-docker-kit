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

## 6. 自动发布说明（检测原理、脆弱点、tag 语义）

- **检测原理**：每天一次定时任务走双通道——(a) 官网下载页内嵌版本信息（版本号 + 官方 hash），变化且 Hub 无对应版本 tag 即触发 ISO 分支；(b) OTA 版本清单（匿名查询，`trim.version` 为准），变化且 Hub 无对应 `X-ota` tag 即触发 deb 分支（不等 ISO）。两通道 state 各记各的，互不阻塞。下载直链有时效，每次构建时现场获取，不硬编码。
- **已知脆弱点**：官网改版（页面结构/字段变化）会导致检测失败——此时流水线显式失败并自动开 Issue，不会静默当成"无新版"；直链下载被拦截时同样开 Issue，需人工提供 ISO 后手动触发构建；OTA 未文档化 endpoint 变更只影响 deb 分支，不连累 ISO 分支。
- **tag 语义**：`1.2.0701` 式版本 tag 对应 fnOS 版本，一次构建不变；`latest` 恒指向最近一次 **ISO 全量**构建成功的版本；构建失败绝不碰任何 tag。
- **补丁失效**：新版上补丁未全命中时不推送镜像，CI 失败并自动开 Issue（含逐条补丁通过/挂起清单，标题区分 `X` / `X-ota`），等人工 rebase 出新补丁集后再构建；无补丁集时走"需 rebase" Issue，不做无谓构建。

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
