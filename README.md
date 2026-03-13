# ubuntu-vps-init

Ubuntu 22.04 / 24.04 VPS 初始化脚本。

## 功能

- 创建 `ubuntu` 用户
- 配置 SSH key 登录
- 修改 SSH 端口
- 禁用密码登录
- 安装 Docker / Docker Compose
- 配置 swap
- 启用 BBR
- 配置 fail2ban
- 清理 snapd

## 交互使用

```bash
# 初始化脚本
curl -fsSL https://raw.githubusercontent.com/volcano6/init-vps/main/init-vps.sh -o init-vps.sh
sudo bash init-vps.sh

# 初始化vless
curl -fsSL https://raw.githubusercontent.com/volcano6/init-vps/main/vless.sh -o vless.sh
sudo bash vless.sh
```