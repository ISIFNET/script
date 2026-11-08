# ISIF Script

这个仓库提供 DNS、Proxmox VE 和 Debian 主机维护脚本。所有会改动系统的脚本都默认先检查或预览；升级和重启必须通过显式参数触发。

## Proxmox VE

### 修复订阅源

`script/pve-subscription-fix.sh` 支持 PVE 8 和 PVE 9：

```bash
sudo bash script/pve-subscription-fix.sh --check
sudo bash script/pve-subscription-fix.sh --dry-run
sudo bash script/pve-subscription-fix.sh
```

脚本会备份源文件，禁用 `pve-enterprise`，并按 PVE 主版本启用 `pve-no-subscription`（PVE 8 使用 bookworm，PVE 9 使用 trixie）。它不会修改 Proxmox Web UI 的订阅提示，也不会安装第三方密钥。

### PVE 8 升级 PVE 9

`script/pve8-to-pve9.sh` 的默认行为是只检查。推荐先使用控制台或 `tmux`，确认备份有效，并阅读 [Proxmox VE 管理指南](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)。

```bash
sudo bash script/pve8-to-pve9.sh
sudo bash script/pve8-to-pve9.sh --prepare
sudo bash script/pve8-to-pve9.sh --upgrade
sudo bash script/pve8-to-pve9.sh --upgrade --yes --reboot
```

升级前会调用官方 `pve8to9 --full` 检查器，先更新 PVE 8，再切换 Debian/PVE 源到 trixie，最后执行 `apt-get full-upgrade`。Ceph 大版本和第三方源不会被脚本猜测处理；检查器或 APT 报错时应先人工修复。

### 默认关闭嵌套虚拟化

`script/disable-nested-virtualization.sh` 会为 Intel 和 AMD KVM 模块写入持久配置，默认关闭嵌套虚拟化：

```bash
sudo bash script/disable-nested-virtualization.sh
sudo bash script/disable-nested-virtualization.sh --status
sudo bash script/disable-nested-virtualization.sh --dry-run
```

配置在模块下次加载时生效，已有虚拟机不会被强制停止；通常重启主机后再用 `--status` 验证。只有明确需要时才使用 `--enable`。

## Debian 12 → 13

### Debian 源修复

Debian 本身没有 Proxmox 式订阅仓库。`script/debian-subscription-fix.sh` 只处理常见的无效企业源或 CD-ROM 源，并确保 Debian 官方源和安全更新源存在：

```bash
sudo bash script/debian-subscription-fix.sh --check
sudo bash script/debian-subscription-fix.sh --dry-run
sudo bash script/debian-subscription-fix.sh
```

在 Proxmox 主机上请使用上面的 PVE 脚本，不要让两个脚本同时管理源文件。

### Debian 12 升级 Debian 13

`script/debian12-to-13.sh` 默认只检查，支持准备源或执行完整升级：

```bash
sudo bash script/debian12-to-13.sh
sudo bash script/debian12-to-13.sh --prepare
sudo bash script/debian12-to-13.sh --upgrade
sudo bash script/debian12-to-13.sh --upgrade --yes --reboot
```

升级顺序参考 [Debian 13 Release Notes](https://www.debian.org/releases/trixie/release-notes/upgrading.en.html)：检查 dpkg 状态、保存 `/etc` 和包管理状态、执行 minimal upgrade、切换官方源到 trixie，再执行 full-upgrade。第三方源只会提示，不会被脚本猜测切换。

## DNS

`script/unlock.sh` 保留原有严格 DNS 设置功能，并增加了参数值检查、DNS 地址校验、IP 家族过滤后的空列表检查，以及 `--help` 在非 root 环境下可读等改进：

```bash
sudo bash script/unlock.sh --dns 1.1.1.1,2606:4700:4700::1111
sudo bash script/unlock.sh --dry-run
sudo bash script/unlock.sh --restore
```

脚本会备份 `/etc/resolv.conf`。`--dry-run` 只预览操作，不写系统文件。
