# Linux 网络限速策略自动化部署系统

一个智能的 Linux 网络限速工具，支持带宽限制、延迟、丢包、抖动等多维度网络特性模拟。

## 🚀 快速开始

### 一键安装

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/githubzhangfei/linux-limit/main/install.sh)
```

或者

```bash
curl -Ls https://raw.githubusercontent.com/githubzhangfei/linux-limit/main/install.sh | sudo bash
```

### 支持的系统

- ✅ Debian / Ubuntu
- ✅ CentOS / RHEL / AlmaLinux
- ✅ Alpine Linux
- ✅ 其他使用 `apt-get` 或 `yum` 或 `apk` 的发行版

## 📋 功能特性

- **智能 IP 识别**: 自动获取公网 IP，支持多网卡环境
- **远程策略管理**: 从 API 服务器获取网络限速策略
- **MD5 去重**: 避免策略未变时重复应用，减少系统开销
- **多维度限制**:
  - 🚦 带宽限速（Mbps）
  - ⏱️ 网络延迟（ms）
  - 📊 延迟抖动（ms）
  - 📉 丢包率（%）
- **自动调度**: 每 2 分钟自动检查策略更新
- **完整日志**: `/var/log/net_limit_agent.log`

## 📁 安装后文件

| 文件路径 | 说明 |
|--------|------|
| `/usr/local/bin/net_limit_agent.sh` | 限速策略执行脚本 |
| `/var/log/net_limit_agent.log` | 执行日志文件 |
| `/etc/cron.d/net_limit_agent` | 定时任务配置 |

## 🔧 手动操作

### 查看实时日志

```bash
tail -f /var/log/net_limit_agent.log
```

### 立即执行一次限速更新

```bash
/usr/local/bin/net_limit_agent.sh
```

### 查看当前网卡限速规则

```bash
tc qdisc show
```

### 移除所有限速规则

```bash
# 获取网卡名称（一般为 eth0 或 ens0）
ip route | grep default | awk '{print $5}'

# 删除限速规则（替换 eth0 为实际网卡名）
sudo tc qdisc del dev eth0 root
```

## 📡 API 接口说明

系统向 `http://zora.dianpingping.top:1024/api/computer/limit` 发送请求

**请求参数:**
```
GET /api/computer/limit?client_ip=YOUR_PUBLIC_IP
```

**响应格式:**
```json
{
  "enabled": 1,
  "limitMbps": 10,
  "loss": 1,
  "delayMs": 50,
  "jitterMs": 10
}
```

**字段说明:**
- `enabled`: 1 启用 / 0 禁用
- `limitMbps`: 带宽限制（单位：Mbps）
- `loss`: 丢包率（单位：%）
- `delayMs`: 延迟（单位：毫秒）
- `jitterMs`: 延迟抖动（单位：毫秒）

## 🛠️ 卸载

删除以下文件即可完全卸载：

```bash
sudo rm -f /usr/local/bin/net_limit_agent.sh
sudo rm -f /var/log/net_limit_agent.log
sudo rm -f /etc/cron.d/net_limit_agent

# 移除限速规则
IFACE=$(ip route | awk '/default/ {print $5; exit}')
sudo tc qdisc del dev $IFACE root 2>/dev/null
```

## ⚠️ 注意事项

1. **需要 root 权限**: 修改网络限速规则需要管理员权限
2. **网络环境**: 需要能够连接外部 API 服务器
3. **生产环境**: 在应用到生产环境前，建议先在测试环境验证
4. **数据备份**: 安装前建议备份重要数据

## 🐛 故障排查

### 1. 显示权限不足

```bash
# 确保使用 sudo 执行
sudo bash <(curl -Ls https://raw.githubusercontent.com/githubzhangfei/linux-limit/main/install.sh)
```

### 2. 无法获取公网 IP

```bash
# 检查网络连接
curl https://api4.ipify.org
```

### 3. 查看详细错误日志

```bash
tail -f /var/log/net_limit_agent.log
```

### 4. 手动测试脚本

```bash
sudo /usr/local/bin/net_limit_agent.sh
```

## 📞 技术支持

- 📝 查看完整日志: `tail -f /var/log/net_limit_agent.log`
- 🔍 检查 cron 状态: `systemctl status cron` 或 `systemctl status crond`
- 🌐 测试 API 连接: `curl http://zora.dianpingping.top:1024/api/computer/limit?client_ip=YOUR_IP`

## 📄 许可证

MIT License