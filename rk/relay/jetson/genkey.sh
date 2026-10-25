#!/bin/bash
# 在车端（Jetson Orin）生成 ed25519 密钥对，并打印公钥。
#
# 为什么不直接用 `ssh ros 'ssh-keygen -N "" ...'`：
#   PowerShell -> ssh.exe 会重新分词，双引号可能被吃掉，远端 bash 就收到
#   一个孤零零的 -N，ssh-keygen 报 "option requires an argument"。
#   放进脚本文件里执行可以彻底避开这个坑。
set -u

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ -f "$HOME/.ssh/id_ed25519" ]; then
  echo "STATE=existing"
else
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C "$(id -un)@$(hostname)"
  echo "STATE=created"
fi

chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub"
echo "---PUBKEY---"
cat "$HOME/.ssh/id_ed25519.pub"
