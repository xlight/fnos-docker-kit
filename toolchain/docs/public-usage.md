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

## 5. 免责声明

- 本工具链基于对 fnOS 行为的逆向分析；飞牛官方更新可能使其部分或全部失效——失效时请按 Issue 模板反馈（含版本与失败报告）。
- 请仅将本工具用于你合法取得的官方 ISO；自行承担使用风险。
- 发布衍生镜像前请阅读仓库的来源声明与下架响应承诺（如有）。

## 6. 社区协作规则（CONTRIBUTING）

- **PR 只收本公开仓**：文档、workflow、构建逻辑的改进欢迎直接提 PR。
- **反向 port**：公开仓是由私有真源生成的；合入的 PR 会由维护者反向 port 回私有仓，下次同步时以真源为准（直接改公开生成物可能被覆盖）。
- **Issue 内容规则**：只放结果型信息（版本、命令、失败报告、日志片段）；不要放推导方法与内部分析过程。
