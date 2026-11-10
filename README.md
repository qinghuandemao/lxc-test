# LXC 网络检测与运行时优化

用于 Linux / LXC 容器的 Bash 脚本，检查 BBR、TCP 缓冲区、连接队列、网卡和连接跟踪状态，并提供可选的交互式运行时调整。

脚本文件：[check-lxc-network.sh](check-lxc-network.sh)

## 下载与运行

在需要检测的 Linux / LXC 容器终端中执行，下载成功后再运行：

```bash
curl -fL https://raw.githubusercontent.com/qinghuandemao/lxc-test/main/check-lxc-network.sh -o check-lxc-network.sh
sudo bash check-lxc-network.sh
```

> **注意：不带参数不是只读检测。** 默认进入全功能交互优化，输入 `yes` 后会尝试修改运行时网络参数。建议先阅读脚本，并使用下方的只读命令检查环境。

默认运行流程：

1. 读取当前网络参数，并询问是否继续优化。
2. 输入 `yes` 继续；其他输入取消优化。
3. 输入容器带宽，单位为 Mbps，例如 `100`、`500` 或 `1000`。
4. 输入 RTT，单位为毫秒；直接回车使用默认值 `100`。
5. 尝试应用调整，输出检测信息、调整状态和被拒绝的项目。

已经是 root 用户时，可以直接执行 `bash check-lxc-network.sh`，不需要 `sudo`。

## 只读检测

仅输出 JSON 检测结果，不修改网络参数，也不需要 root：

```bash
bash check-lxc-network.sh --json
```

保存检测结果：

```bash
bash check-lxc-network.sh --json > lxc-network.json
```

`--json` 必须单独使用才能保持只读；与 `--try-enable`、`--tune`、`--optimize` 或 `--all` 组合仍可能修改参数。

## 检测与调整项目

- BBR 是否可用、当前 TCP 拥塞控制算法和默认队列算法。
- TCP 收发缓冲区及系统缓冲区上限。
- 网络接收队列、连接队列、SYN 队列和 TCP Fast Open。
- conntrack 当前数量和上限。
- 默认网卡、MTU、接口统计和文件描述符上限。
- 可选尝试 BBR / fq、缓冲区、队列和 conntrack 调整，以及 GRO / GSO / TSO / SG 网卡 offload。

按带宽调整的缓冲区上限按 **4 倍带宽时延积**计算，限制在 **4 MiB 至 64 MiB**。这不是测速功能，也不保证所有环境都能获得性能提升。

## 参数说明

| 参数 | 行为 |
| --- | --- |
| 无参数 | 默认全功能交互优化，输入 `yes` 后尝试修改参数。 |
| `--json` | 单独使用时只读，输出 JSON。 |
| `--try-enable` | 实际尝试写入 BBR / fq 和 32 MiB 缓冲区，不只是检查权限，也没有额外的 `yes` 确认。 |
| `--tune` | 询问带宽和 RTT 后实际调整 TCP 缓冲区。 |
| `--optimize` | 确认后执行交互式运行时优化，与默认模式相同。 |
| `--all` | 与 `--optimize` 相同。 |
| `-h` / `--help` | 显示帮助。 |

常用命令：

```bash
# 查看帮助
bash check-lxc-network.sh --help

# 尝试写入 BBR / fq 和 32 MiB 缓冲区，会修改运行时参数
sudo bash check-lxc-network.sh --try-enable

# 按带宽和 RTT 调整缓冲区
sudo bash check-lxc-network.sh --tune

# 交互式运行时优化
sudo bash check-lxc-network.sh --optimize
```

## 环境要求

- Linux 和 Bash，主要面向 LXC 容器；不能直接在 Windows PowerShell 中运行。
- 检测需要 `ip`、`sysctl` 以及常见的 `awk`、`grep`、`sed` 等命令。
- 上方下载命令需要 `curl`；修改参数需要 root 权限。
- `ethtool` 为可选依赖，未安装时跳过网卡 offload 调整。

## 注意事项

- 修改只作用于当前运行时，不自动写入持久化 sysctl 配置；重启后可能恢复或由系统配置重新应用。
- 脚本不会自动备份或回滚参数。部分写入失败时，已经成功的修改仍可能保留。
- LXC 与宿主机共享内核。部分参数不可在容器内修改，出现“被拒绝”时需要检查宿主机内核支持、权限及容器配置；不要为了运行脚本随意扩大容器权限。
- 对特权容器或共享网络命名空间，应先确认参数的影响范围，避免影响宿主机或其他工作负载。
- BBR 需要宿主机内核支持；脚本不会安装内核或自动加载宿主机模块。
- 不自动修改 MTU，也不能绕过宿主机、Proxmox、LXD 或上游网络的带宽限制。
- 检测数值在调整前采集，因此同次输出中的参数不一定是修改后的值。调整后可再次运行 `--json` 查看支持输出的当前参数。
- 脚本最后的“常用命令”将无参数运行标为“只读检测”，但实际无参数会进入交互优化；只读检测请以本页的 `--json` 命令为准。
