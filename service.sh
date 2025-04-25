#!/bin/bash
# ===============================================
# 脚本名称: service.sh
# 描述: Java服务管理工具（支持多JAR操作）（启动/停止/重启/回滚）
# 作者: zhuo <zhuodada1032@163.com>
# 版本: v1.0.0
# 创建日期: 2025-04-25 10:05:21
# 最近更新: 2025-04-25 10:05:21
# 许可证: Apache License 2.0
# 使用方式:
#  启动服务: ./service.sh -s
#  停止服务: ./service.sh -c
#  重启服务: ./service.sh -r
# ===============================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
# 无色
NC='\033[0m'

# JDK配置
export JAVA_HOME=/usr/java/jdk1.8.0_151
export JRE_HOME=$JAVA_HOME/jre
export PATH=$JAVA_HOME/bin:$PATH

# 默认配置
PID_FILE=".pids"
ALL_PACKAGE="true"
FILE_LIST=""
JVM_XMX="512m"
JVM_XMS="128m"
SLEEP_TIME=5
HEALTH_TIME=60
HEALTH_TIME_INTERVAL=5
ROLLBACK_JARS=""
SKIP_CONFIRM="false"
# 启动配置文件
START_CONFIG_FILE="./application.properties"
# 使用说明
usage() {
  echo -e "${GREEN}Usage: $0 [options]${NC}"
  echo "Options:"
  echo "  -h                  显示帮助信息"
  echo "  -s        [name]    启动服务(可选jar名称)"
  echo "  -r        [name]    重启服务(可选jar名称)"
  echo "  -c        [name]    关闭服务(可选jar名称)"
  echo "  -p        <name>    指定jar名称"
  echo "  -config   <name>    指定配置文件"
  echo "  -ht       <sec>     健康检查时间(默认:60秒)"
  echo "  -hi       <sec>     健康检查时间间隔(默认:5秒)"
  echo "  -a                  使用目录中的所有jar文件"
  echo "  -mx       <size>    jvm最大内存(默认:512m)"
  echo "  -ms       <size>    jvm初始内存(默认:128m)"
  echo "  -sleep    <sec>     连续启动休眠时间(默认:5秒)"
  echo "  -b                  版本回滚"
  echo "  -y                  跳过确认"
  exit 1
}

# 日志函数
log_info() {
  echo -e "${BLUE}[INFO] $(date +'%Y-%m-%d %H:%M:%S') ${1}${NC}"
}

log_warn() {
  echo -e "${YELLOW}[WARN] $(date +'%Y-%m-%d %H:%M:%S') ${1}${NC}"
}

log_error() {
  echo -e "${RED}[ERROR] $(date +'%Y-%m-%d %H:%M:%S') ${1}${NC}" >&2
}

# 验证jar文件
verify_jars() {
  if [ "$ALL_PACKAGE" = "true" ]; then
    FILE_LIST=$(find . -type f | grep -vE "backup|replace" | grep \\.jar)
  elif [ -n "$ALL_PACKAGE" ]; then
    FILE_LIST=$(find . -type f | grep -vE "backup|replace" | grep "${ALL_PACKAGE}" | grep \\.jar)
  fi
  if [ -z "$FILE_LIST" ]; then
    log_error "找不到可执行jar文件"
    exit 1
  fi

  log_info "已选中以下jar文件:"
  for jar in $FILE_LIST; do
    echo "  $(basename "$jar")"
  done

  # 只有在非-y模式且终端运行时才询问确认
  if [ "$SKIP_CONFIRM" = "false" ] && [ -t 0 ]; then
    read -p "是否继续执行? [y/N]: " choice
    case "$choice" in
    [yY]) ;;
    *) exit 0 ;;
    esac
  else
    log_info "跳过确认，直接执行"
  fi
  manage_pid_file "clean"
}

# 启动服务
start_service() {
  backup_jars

  local jvm_opts=""
  if [ -f "${START_CONFIG_FILE}" ]; then
    log_info "加载${START_CONFIG_FILE}配置"
    while IFS= read -r line; do
      line=$(echo "$line" | sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ -n "$line" ] && ! [[ "$line" =~ ^# ]]; then
        jvm_opts="$jvm_opts -D$line"
      fi
    done <"${START_CONFIG_FILE}"
  else
    log_warn "${START_CONFIG_FILE} 文件不存在跳过加载"
  fi

  log_info "JVM参数: -Xms${JVM_XMS} -Xmx${JVM_XMX}"
  log_info "启动参数: ${jvm_opts}"

  for jar in $FILE_LIST; do
    local jar_name=$(basename "$jar")
    log_info "启动 $jar_name ..."

    nohup java -Xms$JVM_XMS -Xmx$JVM_XMX $jvm_opts -jar "$jar" >/dev/null 2>&1 &
    local pid=$!

    anage_pid_file "add" "$jar" "$pid"
    log_info "启动完成 $jar_name PID=$pid"
    # 异步健康检查 60秒
    (check_service_health "$jar_name" "$pid" "$jar" &)
    log_warn "休眠${SLEEP_TIME}秒"
    sleep "$SLEEP_TIME"

  done
}

# PID文件管理
manage_pid_file() {
  local operation=$1 jar=$2 pid=$3
  (
    flock -x 200
    case "$operation" in
    "add")
      echo "$jar $pid" >>"$PID_FILE"
      ;;
    "remove")
      grep -v "$jar" "$PID_FILE" >"${PID_FILE}.tmp"
      mv "${PID_FILE}.tmp" "$PID_FILE"
      ;;
    "clean")
      # 清理无效PID
      while read -r line; do
        local file_pid=$(echo "$line" | awk '{print $2}')
        if ! ps -p "$file_pid" >/dev/null; then
          log_warn "清理无效PID: $file_pid (对应jar: $(echo "$line" | awk '{print $1}'))"
        else
          echo "$line"
        fi
      done <"$PID_FILE" >"${PID_FILE}.tmp"
      mv "${PID_FILE}.tmp" "$PID_FILE"
      ;;
    "lock")
      # 获取独占锁
      flock -x 200
      ;;
    "unlock")
      # 释放锁
      flock -u 200
      ;;
    esac
  ) 200>"$LOCK_FILE"
}

# 异步健康检查函数
check_service_health() {
  local jar_name=$1 pid=$2 jar=$3
  local elapsed=0

  while [ $elapsed -lt $HEALTH_TIME ]; do
    if ! ps -p $pid >/dev/null; then
      log_error "[异步检测] 服务 $jar_name (PID:$pid) 已退出!"
      manage_pid_file "remove" "$jar"
      return 1
    fi

    sleep $HEALTH_TIME_INTERVAL
    elapsed=$((elapsed + HEALTH_TIME_INTERVAL))
  done

  log_warn "[异步检测] 服务 $jar_name 启动超时(等待${HEALTH_TIME}秒)，但进程仍在运行"
}
# 停止服务
stop_service() {
  if [ ! -f $PID_FILE ]; then
    log_error "找不到PID文件 $PID_FILE"
    return 1
  fi

  for jar in $FILE_LIST; do
    local pids=$(grep "$jar" $PID_FILE | awk '{print $2}')

    if [ -z "$pids" ]; then
      log_warn "没有找到 $jar 的运行进程"
      continue
    fi

    for pid in $pids; do
      if ps -p $pid >/dev/null; then
        log_info "停止进程 $pid (对应jar: $(basename "$jar"))"
        kill -9 $pid
      else
        log_warn "进程 $pid 不存在"
      fi
    done

    # 从PID文件中移除相关条目
    manage_pid_file "remove" "$jar"
  done
}

# 备份jar文件
backup_jars() {
  local backup_dir="./backup/$(date +%Y-%m-%d)/$(date +%H-%M-%S)"
  mkdir -p "$backup_dir"

  for jar in $FILE_LIST; do
    local jar_name=$(basename "$jar")
    log_info "备份 $jar_name 到 $backup_dir/"
    cp "$jar" "$backup_dir/"
  done

  log_info "备份完成，位置: $backup_dir"
}

# 重启服务
restart_service() {
  stop_service
  sleep 2
  start_service
}

# 版本回退
rollback_jars() {
  local backup_dirs=$(ls -lt backup 2>/dev/null | grep -v total | awk '{print $9}' | nl -v 1)

  if [ -z "$backup_dirs" ]; then
    log_error "找不到备份目录"
    return 1
  fi

  echo "$backup_dirs"
  read -p "请选择备份日期: " dir_choice
  local selected_dir=$(echo "$backup_dirs" | sed -n "${dir_choice}p" | awk '{print $2}')

  if [ -z "$selected_dir" ]; then
    log_error "无效选择"
    return 1
  fi

  local backup_files=$(find "backup/${selected_dir}" -type f -name "*.jar" | nl -v 1)
  echo "$backup_files"
  read -p "请选择要恢复的jar文件: " file_choice
  local selected_file=$(echo "$backup_files" | sed -n "${file_choice}p" | awk '{print $2}')

  if [ -z "$selected_file" ]; then
    log_error "无效选择"
    return 1
  fi

  local current_jars=$(find . -type f -name "*.jar" | grep -vE 'backup|replace' | nl -v 1)
  echo "$current_jars"
  read -p "请选择要替换的jar文件: " replace_choice
  local replace_jar=$(echo "$current_jars" | sed -n "${replace_choice}p" | awk '{print $2}')

  if [ -z "$replace_jar" ]; then
    log_error "无效选择"
    return 1
  fi

  # 执行回滚操作
  log_info "回滚 ${replace_jar} 到 ${selected_file}"
  mv "${replace_jar}" "${replace_jar}-replace"
  cp "${selected_file}" "${replace_jar}"

  ROLLBACK_JARS="${ROLLBACK_JARS}${replace_jar}\n"

  read -p "是否继续选择其他文件回滚? [Y/n]: " choice
  case "$choice" in
  [nN]) perform_rollback ;;
  *) rollback_jars ;;
  esac
}

perform_rollback() {
  log_info "开始执行回滚操作"
  FILE_LIST=$(echo -e "$ROLLBACK_JARS" | tr -d '\n')
  restart_service
}

# 状态检查
check_service_status() {
  manage_pid_file "clean"
  if [ ! -f "$PID_FILE" ]; then
    log_info "没有服务在运行"
    return 1
  fi

  local all_running=true
  while read -r line; do
    local jar=$(echo "$line" | awk '{print $1}')
    local pid=$(echo "$line" | awk '{print $2}')

    if ps -p "$pid" >/dev/null; then
      log_info "服务 $(basename "$jar") 正在运行 (PID: $pid)"
    else
      log_warn "服务 $(basename "$jar") PID存在但进程未运行 (PID: $pid)"
      all_running=false
    fi
  done <"$PID_FILE"

  $all_running && return 0 || return 1
}
# 检查命令是否存在
check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "需要安装 $1 命令"
    exit 1
  fi
}

# 初始化检查
init_checks() {
  # 检查磁盘空间
  local disk_avail=$(df -k . | awk 'NR==2 {print $4}')
  if [ "$disk_avail" -lt 1048576 ]; then # 小于1GB
    log_warn "可用磁盘空间不足 (剩余: $((disk_avail / 1024))MB)"
  fi
}
# 主函数
main() {
  local action=""
  init_checks
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h) usage ;;
    -sleep)
      if [[ $# -gt 1 && $2 != -* ]]; then
        SLEEP_TIME="$2"
        log_info "设置连续执行休眠时间: ${SLEEP_TIME}秒"
        shift
      fi
      shift
      ;;
    -mx)
      if [[ $# -gt 1 && $2 != -* ]]; then
        JVM_XMX="$2"
        log_info "设置JVM最大内存: ${JVM_XMX}"
        shift
      fi
      shift
      ;;
    -ms)
      if [[ $# -gt 1 && $2 != -* ]]; then
        JVM_XMS="$2"
        log_info "设置JVM初始内存: ${JVM_XMS}"
        shift
      fi
      shift
      ;;
    -ht)
      if [[ $# -gt 1 && $2 != -* ]]; then
        HEALTH_TIME="$2"
        log_info "设置健康监测时间为: ${HEALTH_TIME} 秒"
        shift
      fi
      shift
      ;;
    -hl)
      if [[ $# -gt 1 && $2 != -* ]]; then
        HEALTH_TIME_INTERVAL="$2"
        log_info "设置健康监测时间间隔为: ${HEALTH_TIME_INTERVAL} 秒"
        shift
      fi
      shift
      ;;
    -config)
      if [[ $# -gt 1 && $2 != -* ]]; then
        START_CONFIG_FILE="$2"
        log_info "指定配置文件: ${START_CONFIG_FILE}"
        shift
      fi
      shift
      ;;
    -s)
      action="start"
      if [[ $# -gt 1 && $2 != -* ]]; then
        ALL_PACKAGE="$2"
        shift
      fi
      shift
      ;;
    -b)
      action="rollback"
      if [[ $# -gt 1 && $2 != -* ]]; then
        ALL_PACKAGE="$2"
        shift
      fi
      shift
      ;;
    -r)
      action="restart"
      if [[ $# -gt 1 && $2 != -* ]]; then
        ALL_PACKAGE="$2"
        shift
      fi
      shift
      ;;
    -c)
      action="stop"
      if [[ $# -gt 1 && $2 != -* ]]; then
        ALL_PACKAGE="$2"
        shift
      fi
      shift
      ;;
    -p)
      if [[ $# -gt 1 && $2 != -* ]]; then
        ALL_PACKAGE="$2"
        shift
      else
        log_error "-p 参数需要指定jar名称"
        usage
      fi
      ;;
    -a)
      ALL_PACKAGE="true"
      shift
      ;;
    -y)
      SKIP_CONFIRM="true"
      log_warn "跳过二次确认"
      shift
      ;;
    -status)
      action="status"
      if [[ $# -gt 1 && $2 != -* ]]; then
        ALL_PACKAGE="$2"
        shift
      fi
      ;;
    *)
      log_error "未知选项: $1"
      usage
      ;;
    esac
  done

  case "$action" in
  "start") log_info "执行${GREEN}启动${NC}操作" ;;
  "stop") log_info "执行${RED}停止${NC}操作" ;;
  "restart") log_info "执行${WARN}重启${NC}操作" ;;
  "rollback") log_info "执行${RED}回滚${NC}操作" ;;
  "status") log_info "执行${BLUE}状态检查${NC}操作" ;;
  *)
    log_error "未指定有效操作"
    usage
    ;;
  esac

  verify_jars

  case "$action" in
  "start") start_service ;;
  "stop") stop_service ;;
  "restart") restart_service ;;
  "rollback") rollback_jars ;;
  "status") check_service_status ;;
  esac
}

main "$@"
