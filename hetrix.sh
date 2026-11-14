
#!/bin/bash

# ==========================================
# HetrixTools 一键配置管理
# Cron 执行频率 + 内部采样间隔
# ==========================================

CRON_USER="hetrixtools"
AGENT="/etc/hetrixtools/hetrixtools_agent.sh"
CONFIG="/etc/hetrixtools/hetrixtools.cfg"
LOG="/etc/hetrixtools/hetrixtools_cron.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

line() {
    echo "=================================================="
}

get_cron() {
    crontab -u "$CRON_USER" -l 2>/dev/null
}

# 显示当前状态
show_status() {
    echo
    line
    echo -e "${CYAN}          HetrixTools 当前运行配置${NC}"
    line

    echo
    echo "[1] 当前 Cron 计划任务："

    CURRENT_CRON=$(get_cron)
    if [ -n "$CURRENT_CRON" ]; then
        echo "$CURRENT_CRON"
    else
        echo "未找到 Cron 任务"
    fi

    echo
    echo "[2] 当前采样间隔："

    CURRENT_SAMPLE=$(grep '^CollectEveryXSeconds=' "$CONFIG" |
        tail -n 1 | cut -d= -f2)

    if [[ "$CURRENT_SAMPLE" =~ ^[0-9]+$ ]]; then
        echo "每 ${CURRENT_SAMPLE} 秒采样一次"
    else
        echo "无法读取采样间隔"
    fi

    echo
    echo "[3] 当前运行进程："
    pgrep -af "$AGENT" || echo "当前没有运行中的采样脚本"

    line
}

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本。${NC}"
    exit 1
fi

# 检查文件和用户
if ! id "$CRON_USER" >/dev/null 2>&1; then
    echo -e "${RED}错误：HetrixTools 用户不存在。${NC}"
    exit 1
fi

if [ ! -f "$AGENT" ] || [ ! -f "$CONFIG" ]; then
    echo -e "${RED}错误：HetrixTools 文件不存在。${NC}"
    exit 1
fi

# 检查采样配置是否唯一
CONFIG_COUNT=$(grep -c '^CollectEveryXSeconds=' "$CONFIG")

if [ "$CONFIG_COUNT" -ne 1 ]; then
    echo -e "${RED}错误：采样配置项数量异常，停止修改。${NC}"
    exit 1
fi

# 第一阶段：显示当前状态
show_status

# 第二阶段：询问是否修改
echo
read -r -p "是否需要修改 HetrixTools 配置？(y/n)： " CHANGE

case "$CHANGE" in
    y|Y|yes|YES) ;;
    *)
        echo
        echo "已取消，未修改任何配置。"
        exit 0
        ;;
esac

# 第三阶段：询问 Cron 执行频率
echo
line
echo -e "${CYAN}请设置 Cron 执行频率${NC}"
echo "例如：输入 1 表示每分钟执行一次"
echo "      输入 2 表示每两分钟执行一次"
echo "      输入 5 表示每五分钟执行一次"
echo "      输入 60 表示每小时执行一次"
line

while true; do
    read -r -p "请输入 Cron 每隔多少分钟执行一次（1-60）： " CRON_MINUTES

    if [[ "$CRON_MINUTES" =~ ^[0-9]+$ ]] &&
       [ "$CRON_MINUTES" -ge 1 ] &&
       [ "$CRON_MINUTES" -le 60 ]; then
        break
    fi

    echo -e "${YELLOW}输入无效，请输入 1-60 之间的整数。${NC}"
done

# 第四阶段：询问采样周期
echo
line
echo -e "${CYAN}请设置 HetrixTools 采样周期${NC}"
echo "例如：输入 3  表示每 3 秒采样一次"
echo "      输入 5  表示每 5 秒采样一次"
echo "      输入 10 表示每 10 秒采样一次"
echo "      输入 15 表示每 15 秒采样一次"
line

while true; do
    read -r -p "请输入每隔多少秒采样一次（1-60）： " SAMPLE_SECONDS

    if [[ "$SAMPLE_SECONDS" =~ ^[0-9]+$ ]] &&
       [ "$SAMPLE_SECONDS" -ge 1 ] &&
       [ "$SAMPLE_SECONDS" -le 60 ]; then
        break
    fi

    echo -e "${YELLOW}输入无效，请输入 1-60 之间的整数。${NC}"
done

# 生成 Cron 表达式
if [ "$CRON_MINUTES" -eq 60 ]; then
    CRON_EXPR="0 * * * *"
else
    CRON_EXPR="*/${CRON_MINUTES} * * * *"
fi

NEW_CRON="$CRON_EXPR bash $AGENT >> $LOG 2>&1"

# 第五阶段：显示修改方案
echo
line
echo -e "${CYAN}              配置修改确认${NC}"
line

echo "当前 Cron："
echo "$CURRENT_CRON"
echo
echo "新的 Cron："
echo "$NEW_CRON"
echo
echo "当前采样间隔：${CURRENT_SAMPLE:-未知} 秒"
echo "新的采样间隔：${SAMPLE_SECONDS} 秒"
echo "每分钟理论采样次数：$((60 / SAMPLE_SECONDS)) 次"

line

read -r -p "确认应用以上修改？(y/n)： " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *)
        echo
        echo "客户取消修改，原配置保持不变。"
        exit 0
        ;;
esac

# 第六阶段：修改 Cron
echo
echo -e "${YELLOW}[1/3] 正在修改 Cron...${NC}"

TMP_FILE=$(mktemp) || exit 1

if ! get_cron > "$TMP_FILE"; then
    echo -e "${RED}无法读取原 Cron 配置。${NC}"
    rm -f "$TMP_FILE"
    exit 1
fi

# 删除旧的 HetrixTools Agent 任务，保留其他任务
grep -vF "$AGENT" "$TMP_FILE" > "${TMP_FILE}.new"
echo "$NEW_CRON" >> "${TMP_FILE}.new"

if ! crontab -u "$CRON_USER" "${TMP_FILE}.new"; then
    echo -e "${RED}Cron 修改失败。${NC}"
    rm -f "$TMP_FILE" "${TMP_FILE}.new"
    exit 1
fi

rm -f "$TMP_FILE" "${TMP_FILE}.new"

echo -e "${GREEN}Cron 修改完成。${NC}"

# 第七阶段：修改采样间隔
echo
echo -e "${YELLOW}[2/3] 正在修改采样间隔...${NC}"

if ! sed -i \
    "s/^CollectEveryXSeconds=.*/CollectEveryXSeconds=${SAMPLE_SECONDS}/" \
    "$CONFIG"; then
    echo -e "${RED}采样间隔修改失败。${NC}"
    exit 1
fi

echo -e "${GREEN}采样间隔修改完成。${NC}"

# 第八阶段：重新读取文件
echo
echo -e "${YELLOW}[3/3] 正在读取文件并验证...${NC}"

FINAL_CRON=$(get_cron)
FINAL_SAMPLE=$(grep '^CollectEveryXSeconds=' "$CONFIG" |
    tail -n 1 | cut -d= -f2)

echo
echo "========== 实际 Cron 配置 =========="
echo "$FINAL_CRON"

echo
echo "========== 实际采样配置 =========="
grep -n '^CollectEveryXSeconds=' "$CONFIG"

# 第九阶段：验证
CRON_OK=0
SAMPLE_OK=0

if [ "$(echo "$FINAL_CRON" | grep -Fc "$AGENT")" -eq 1 ] &&
   echo "$FINAL_CRON" | grep -Fxq "$NEW_CRON"; then
    CRON_OK=1
fi

if [ "$FINAL_SAMPLE" = "$SAMPLE_SECONDS" ]; then
    SAMPLE_OK=1
fi

echo
line
echo -e "${CYAN}              最终执行结果${NC}"
line

if [ "$CRON_OK" -eq 1 ]; then
    echo -e "${GREEN}Cron 验证成功：每 ${CRON_MINUTES} 分钟执行一次${NC}"
else
    echo -e "${RED}Cron 验证失败${NC}"
fi

if [ "$SAMPLE_OK" -eq 1 ]; then
    echo -e "${GREEN}采样验证成功：每 ${SAMPLE_SECONDS} 秒采样一次${NC}"
else
    echo -e "${RED}采样验证失败${NC}"
fi

if [ "$CRON_OK" -eq 1 ] && [ "$SAMPLE_OK" -eq 1 ]; then
    echo
    echo -e "${GREEN}所有配置修改成功！${NC}"
    echo "无需重启 VPS 或 Cron 服务。"
    echo "正在运行的旧脚本不会被强制终止。"
    echo "新配置将在下一轮脚本启动时生效。"
else
    echo
    echo -e "${RED}配置未全部通过验证，请检查上方结果。${NC}"
    exit 1
fi

line

