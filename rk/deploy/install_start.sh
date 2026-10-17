#!/bin/bash
# 把 start.sh 装进开发板的 PATH 并实测
set -u

echo "########## 1) 安装到 /usr/local/bin/start.sh ##########"
install -m 755 /root/start.sh /usr/local/bin/start.sh
ls -l /usr/local/bin/start.sh

echo ""
echo "########## 2) 检查 PATH ##########"
echo "  当前 PATH = $PATH"
case ":$PATH:" in
  *:/usr/local/bin:*) echo "  OK /usr/local/bin 已在 PATH, 直接敲 start.sh 即可" ;;
  *)
     echo "  /usr/local/bin 不在 PATH, 写入 /etc/profile.d 和 ~/.bashrc"
     printf 'export PATH=/usr/local/bin:$PATH\n' > /etc/profile.d/zz-localbin.sh
     chmod 644 /etc/profile.d/zz-localbin.sh
     grep -q '/usr/local/bin' ~/.bashrc 2>/dev/null || \
         printf '\nexport PATH=/usr/local/bin:$PATH\n' >> ~/.bashrc
     echo "  已写入; 当前会话执行 export PATH=/usr/local/bin:\$PATH 即可立即生效"
     ;;
esac
echo "  /etc/profile: "; grep -n 'usr/local/bin' /etc/profile 2>/dev/null | head -2

echo ""
echo "########## 3) 语法检查 ##########"
bash -n /usr/local/bin/start.sh && echo "  语法 OK"

echo ""
echo "########## 4) start.sh status (启动前) ##########"
bash /usr/local/bin/start.sh status

echo ""
echo "########## 5) 实测: start.sh 1080 ##########"
bash /usr/local/bin/start.sh 1080
