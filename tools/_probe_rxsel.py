import sys, os
sys.path.insert(0, "/root/rk/web")
sys.argv = ["probe"]
import mipi_webstream as m

ST = "/tmp/_rxsel_state_test.json"
if os.path.exists(ST):
    os.remove(ST)

print("无存档 ->", m.rx_sel_get(ST), "(应为默认 1)")
m.rx_sel_put(ST, 0)
print("存档 rx_sel=0 ->", m.rx_sel_get(ST), "(应为 0)")
m.rx_sel_put(ST, 1)
print("存档 rx_sel=1 ->", m.rx_sel_get(ST), "(应为 1)")
os.remove(ST)
print("已清理测试文件")
