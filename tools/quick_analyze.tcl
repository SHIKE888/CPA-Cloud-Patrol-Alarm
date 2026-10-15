# =============================================================================
#  quick_analyze.tcl -- 只做 Verilog 分析 (analyze), 不跑综合/布局/布线。
#
#  用途: 快速抓 TD 独有的严格错误 —— 这些 iverilog 抓不到, 例如:
#    - 未声明标识符被当隐式 wire (iverilog 只当 warning)
#    - 端口位选越界  HDL-8007 index N is out of range
#    - 端口名不存在  HDL-8007 'X' is not a port
#    - 端口重复声明  HDL-8007 ANSI port 'X' cannot be redeclared
#  典型耗时几秒, 而不是完整流程的 10 分钟。
#
#  用法 (在 fpga_prj_Runs/syn_1 目录下):
#    & 'F:/Anlogic/TD_Release_2026.1_SP2.200.067/bin/td_commands_prompt.exe' \
#        'F:/.../tools/quick_analyze.tcl'
#  然后看 fpga_prj_Runs/syn_1/td_*.log 里搜 "ERROR"。
# =============================================================================

set prj [file join [pwd] fpga_prj.prj]

if {![file exists $prj]} {
    puts "ERROR: 找不到 $prj (请在 fpga_prj_Runs/syn_1 下运行)"
    exit 1
}

puts "== quick_analyze: open_project $prj"
open_project $prj

puts "== quick_analyze: analyze 所有源文件"
# fpga_prj.prj 已含工程的全部文件列表, 直接调用 analyze 即可
if {[catch {analyze -format verilog} err]} {
    puts "== quick_analyze: analyze 失败 =="
    puts $err
    exit 2
}

puts "== quick_analyze: 分析通过 (若上面没有 ERROR 行)"
exit 0
