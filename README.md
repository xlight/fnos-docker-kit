# fnOS 容器化公开工具链

从飞牛 fnOS **官方 ISO** 构建容器镜像的最小公开集（补丁施加器、版本化补丁集、
成像工具、编排器、部署脚本、自测），配合你自己的官方 ISO 使用。

本仓把发布拆成三个单元：**观察**（每天探测新版，只开一条可见的状态 Issue）、
**构建**（显式声明才出镜像）、**发布**（显式声明才发补丁集 Release）。

```bash
# 1) 看有没有新版（观察单元每天自动跑；这里可手动触发）
gh workflow run public-watch.yml

# 2) 有新版 → 人工 rebase 出补丁集 → 本地演练 → 声明发布（并触发镜像构建）
sudo bash toolchain/rehearse-build.sh --version 1.2.1000
bash toolchain/publish.sh --patchset 1.2.1000 --image 1.2.1000
```

完整用法见 [toolchain/docs/public-usage.md](toolchain/docs/public-usage.md)（安装/构建/部署/边界/免责声明/协作规则）。
