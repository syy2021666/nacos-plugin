#!/bin/bash
#===============================================================================
# Nacos 信创版自动构建脚本
#
# 用途: 构建包含国产数据库插件的 Nacos 完整发行版
#
# 工作原理:
#   1. 构建 nacos-plugin → 每个数据库产生独立的 shaded JAR (内含 JDBC 驱动)
#   2. 构建/下载 nacos 发行版
#   3. 将插件 JAR + schema SQL 复制到 nacos distribution
#   4. 打包最终发行版
#
# 用法:
#   ./build-xinchuang-nacos.sh                          # 全量构建 (所有数据库)
#   ./build-xinchuang-nacos.sh -d dm,kingbase           # 仅达梦+金仓
#   ./build-xinchuang-nacos.sh -n 3.2.2 -d all          # 指定 nacos 版本
#   ./build-xinchuang-nacos.sh --nacos-source ../nacos  # 从本地 nacos 源码构建
#   ./build-xinchuang-nacos.sh --plugin-only            # 仅打包插件,不包含 nacos
#
# 选项:
#   -d, --databases    要包含的数据库 (默认: all)
#                      可选: dm,kingbase,opengauss,xugu,yasdb,oceanbase,mssql,oracle
#   -n, --nacos-ver    Nacos 版本号 (默认: 从 nacos 源码读取)
#   --nacos-source     Nacos 源码目录 (默认: ../nacos)
#   --nacos-release    使用已发布的 nacos 版本 (不从源码编译)
#   --plugin-only      仅构建插件包,不包含 nacos server
#   -o, --output       输出目录 (默认: ./target/xinchuang-dist)
#   -h, --help         显示帮助
#===============================================================================

set -euo pipefail

#===============================================================================
# 配置
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_NACOS_SOURCE_DIR="${PLUGIN_PROJECT_DIR}/../nacos"
OUTPUT_DIR="${SCRIPT_DIR}/../target/xinchuang-dist"

# 所有支持的国产数据库插件模块
# 格式: "模块目录名:数据库标识:显示名称:schema文件名:JDBC驱动说明"
declare -A DB_MODULES
DB_MODULES=(
    ["dm"]="nacos-dm-datasource-plugin-ext:dm:达梦DM:nacos-dm.sql:DmJdbcDriver18(内置)"
    ["kingbase"]="nacos-kingbase-datasource-plugin-ext:kingbase:人大金仓KingbaseES:nacos-kingbase.sql:kingbase8(内置)"
    ["opengauss"]="nacos-opengauss-datasource-plugin-ext:gaussdb:OpenGauss:nacos-openguass-compatible-oracle.sql:opengauss-jdbc(内置)"
    ["xugu"]="nacos-xuguDB-datasource-plugin-ext:xugu:虚谷XuguDB:nacos-xugu.sql:需手动放入plugins/"
    ["yasdb"]="nacos-yasdb-datasource-plugin-ext:yasdb:崖山YasDB:nacos-yasdb.sql:需手动放入plugins/"
    ["oceanbase"]="nacos-oceanbase-datasource-plugin-ext:oceanbase:OceanBase:nacos-oceanbase.sql:oceanbase-client(内置)"
    ["mssql"]="nacos-mssql-datasource-plugin-ext:sqlserver:SQL Server:nacos-mssql.sql:mssql-jdbc(内置)"
    ["oracle"]="nacos-oracle-datasource-plugin-ext:oracle:Oracle(扩展版):nacos-oracle.sql:ojdbc8(内置)"
)

# 需要额外下载 JDBC 驱动的数据库 (驱动不在 Maven Central 或需手动获取)
# 格式: "模块目录名:JDBC下载URL或说明"
declare -A EXTRA_JDBC
EXTRA_JDBC=(
    ["xugu"]="虚谷JDBC驱动需从官网获取: http://www.xugudb.com"
    ["yasdb"]="崖山JDBC驱动需从官网获取: https://www.yashandb.com"
)

NACOS_SOURCE_DIR="${DEFAULT_NACOS_SOURCE_DIR}"
NACOS_VERSION=""
USE_NACOS_RELEASE="false"
PLUGIN_ONLY="false"
SELECTED_DBS="all"

#===============================================================================
# 辅助函数
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}==>${NC} $*"; }

usage() {
    head -30 "$0" | grep -A1 "^# " | head -28
    echo ""
    echo "支持的数据库:"
    for db in "${!DB_MODULES[@]}"; do
        IFS=':' read -r mod type name schema driver <<< "${DB_MODULES[$db]}"
        printf "  %-12s %-20s (驱动: %s)\n" "$type" "$name" "$driver"
    done
    exit 0
}

#===============================================================================
# 参数解析
#===============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--databases)
            SELECTED_DBS="$2"; shift 2 ;;
        -n|--nacos-ver)
            NACOS_VERSION="$2"; shift 2 ;;
        --nacos-source)
            NACOS_SOURCE_DIR="$2"; shift 2 ;;
        --nacos-release)
            USE_NACOS_RELEASE="true"; shift ;;
        --plugin-only)
            PLUGIN_ONLY="true"; shift ;;
        -o|--output)
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            log_error "未知参数: $1"
            usage ;;
    esac
done

# 解析数据库选择
if [ "${SELECTED_DBS}" = "all" ]; then
    BUILD_DBS=("${!DB_MODULES[@]}")
else
    IFS=',' read -ra BUILD_DBS <<< "${SELECTED_DBS}"
    for db in "${BUILD_DBS[@]}"; do
        if [ -z "${DB_MODULES[$db]:-}" ]; then
            log_error "不支持的数据库: $db"
            log_info "可选: ${!DB_MODULES[*]}"
            exit 1
        fi
    done
fi

#===============================================================================
# Step 1: 构建 nacos-plugin 各数据库插件模块
#===============================================================================

build_plugins() {
    log_step "Step 1/4: 构建国产数据库插件"

    cd "${PLUGIN_PROJECT_DIR}"

    # 构建插件模块列表 (加上 -am 自动包含 base 依赖)
    local modules=""
    for db in "${BUILD_DBS[@]}"; do
        IFS=':' read -r mod type name schema driver <<< "${DB_MODULES[$db]}"
        modules="${modules}nacos-datasource-plugin-ext/${mod},"
    done
    modules="${modules%,}"

    log_info "构建模块: ${modules}"

    local mvn_opts="-pl ${modules} -am clean package -DskipTests"
    if [ -n "${NACOS_VERSION}" ]; then
        mvn_opts="${mvn_opts} -Dalibaba-nacos.version=${NACOS_VERSION}"
    fi

    mvn ${mvn_opts} 2>&1 | while IFS= read -r line; do
        case "$line" in
            *"BUILD SUCCESS"*) echo -e "${GREEN}${line}${NC}" ;;
            *"BUILD FAILURE"*) echo -e "${RED}${line}${NC}" ;;
            *"ERROR"*)         echo -e "${RED}${line}${NC}" ;;
            *)                 echo "$line" ;;
        esac
    done

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "插件构建失败!"
        exit 1
    fi
    log_info "插件构建完成"
}

#===============================================================================
# Step 2: 构建/获取 Nacos 发行版
#===============================================================================

build_nacos() {
    log_step "Step 2/4: 获取 Nacos 发行版"

    if [ "${PLUGIN_ONLY}" = "true" ]; then
        log_info "--plugin-only 模式, 跳过 nacos 构建"
        return 0
    fi

    if [ "${USE_NACOS_RELEASE}" = "true" ] && [ -n "${NACOS_VERSION}" ]; then
        # 下载已发布的 nacos 版本
        local nacos_url="https://github.com/alibaba/nacos/releases/download/${NACOS_VERSION}/nacos-server-${NACOS_VERSION}.tar.gz"
        local nacos_tar="/tmp/nacos-server-${NACOS_VERSION}.tar.gz"
        log_info "下载 Nacos ${NACOS_VERSION} 发行版..."
        if command -v wget &> /dev/null; then
            wget -q --show-progress -O "${nacos_tar}" "${nacos_url}" || {
                log_error "下载失败: ${nacos_url}"
                exit 1
            }
        else
            curl -fsSL -o "${nacos_tar}" "${nacos_url}" || {
                log_error "下载失败: ${nacos_url}"
                exit 1
            }
        fi
        NACOS_DIST_DIR=$(mktemp -d /tmp/nacos-dist.XXXXXX)
        tar -xzf "${nacos_tar}" -C "${NACOS_DIST_DIR}" --strip-components=1
        log_info "Nacos 发行版解压到: ${NACOS_DIST_DIR}"
    else
        # 从源码构建 nacos
        if [ ! -d "${NACOS_SOURCE_DIR}" ]; then
            log_error "Nacos 源码目录不存在: ${NACOS_SOURCE_DIR}"
            log_info "请指定: --nacos-source /path/to/nacos 或 --nacos-release --nacos-ver 3.2.2"
            exit 1
        fi
        log_info "从源码构建 Nacos: ${NACOS_SOURCE_DIR}"
        cd "${NACOS_SOURCE_DIR}"
        mvn -Prelease-nacos,!dev clean install -DskipTests -Drat.skip=true -Dspotbugs.skip=true -Dcheckstyle.skip=true -q
        log_info "Nacos 构建完成"

        # 获取 nacos 版本
        if [ -z "${NACOS_VERSION}" ]; then
            NACOS_VERSION=$(cd "${NACOS_SOURCE_DIR}" && mvn help:evaluate -Dexpression=project.version -q -DforceStdout 2>/dev/null || echo "unknown")
        fi
        # nacos 源码构建的 assembly 目录结构:
        # nacos-server-${ver}/
        # └── nacos/    <-- 实际内容在这里
        #     ├── bin/
        #     ├── conf/
        #     ├── plugins/
        #     └── target/
        NACOS_DIST_DIR="${NACOS_SOURCE_DIR}/distribution/target/nacos-server-${NACOS_VERSION}/nacos"
    fi
}

#===============================================================================
# Step 3: 复制插件 JAR 和 Schema SQL
#===============================================================================

copy_artifacts() {
    log_step "Step 3/4: 组装插件到 Nacos 发行版"

    if [ "${PLUGIN_ONLY}" = "true" ]; then
        mkdir -p "${OUTPUT_DIR}/plugins" "${OUTPUT_DIR}/conf"
        PLUGINS_DIR="${OUTPUT_DIR}/plugins"
        CONF_DIR="${OUTPUT_DIR}/conf"
    else
        PLUGINS_DIR="${NACOS_DIST_DIR}/plugins"
        CONF_DIR="${NACOS_DIST_DIR}/conf"
        mkdir -p "${PLUGINS_DIR}" "${CONF_DIR}"
    fi

    local copied_count=0
    for db in "${BUILD_DBS[@]}"; do
        IFS=':' read -r mod type name schema driver <<< "${DB_MODULES[$db]}"

        echo ""
        log_info "--- ${name} (${type}) ---"

        # 复制插件 JAR
        local plugin_dir="${PLUGIN_PROJECT_DIR}/nacos-datasource-plugin-ext/${mod}/target"
        local jar_file=$(ls "${plugin_dir}"/${mod}-*.jar 2>/dev/null | grep -v sources | grep -v javadoc | grep -v original | head -1)

        if [ -n "${jar_file}" ] && [ -f "${jar_file}" ]; then
            cp -v "${jar_file}" "${PLUGINS_DIR}/"
            copied_count=$((copied_count + 1))
            log_info "  插件 JAR: $(basename ${jar_file}) ✓"
        else
            log_warn "  插件 JAR 未找到 (${plugin_dir})"
        fi

        # 复制 Schema SQL
        if [ -n "${schema}" ] && [ "${schema}" != "NONE" ]; then
            local schema_dir="${PLUGIN_PROJECT_DIR}/nacos-datasource-plugin-ext/${mod}/src/main/resources/schema"
            if [ -f "${schema_dir}/${schema}" ]; then
                cp -v "${schema_dir}/${schema}" "${CONF_DIR}/"
                log_info "  Schema:   ${schema} ✓"
            else
                log_warn "  Schema 文件未找到: ${schema_dir}/${schema}"
            fi
        fi

        # 检查 JDBC 驱动
        if [ -n "${EXTRA_JDBC[$db]:-}" ]; then
            log_warn "  ⚠ JDBC 驱动需手动处理: ${EXTRA_JDBC[$db]}"
        fi
    done

    echo ""
    log_info "共复制 ${copied_count} 个插件 JAR"

    # 生成数据库配置说明
    generate_config_doc
}

#===============================================================================
# 生成配置说明文档
#===============================================================================

generate_config_doc() {
    local doc="${CONF_DIR}/DOMESTIC_DB_PLUGINS.md"
    cat > "${doc}" << 'DOCEOF'
# Nacos 国产数据库插件配置指南

## 已包含的数据库插件

DOCEOF

    for db in "${BUILD_DBS[@]}"; do
        IFS=':' read -r mod type name schema driver <<< "${DB_MODULES[$db]}"
        echo "### ${name}" >> "${doc}"
        echo "" >> "${doc}"
        echo "- **数据库类型**: \`${type}\`" >> "${doc}"
        echo "- **配置**: \`nacos.plugin.datasource-dialect.type=${type}\`" >> "${doc}"
        echo "- **Schema**: \`conf/${schema}\`" >> "${doc}"
        echo "- **JDBC驱动**: ${driver}" >> "${doc}"

        if [ -n "${EXTRA_JDBC[$db]:-}" ]; then
            echo "- **⚠ 注意**: ${EXTRA_JDBC[$db]}" >> "${doc}"
        fi
        echo "" >> "${doc}"
    done

    cat >> "${doc}" << 'DOCEOF'

## 使用方法

1. 解压 nacos 发行版
2. 根据目标数据库,执行对应的 schema SQL 初始化数据库:
   ```sql
   -- 以达梦为例
   source conf/nacos-dm.sql
   ```
3. 修改 `conf/application.properties`:
   ```properties
   nacos.plugin.datasource-dialect.type=dm
   nacos.plugin.datasource.db.num=1
   nacos.plugin.datasource.db.url.0=jdbc:dm://127.0.0.1:5236/nacos
   nacos.plugin.datasource.db.user=nacos
   nacos.plugin.datasource.db.password=nacos
   ```
4. 启动: `bin/startup.sh -m standalone`

## 注意事项

- 各插件 JAR 已通过 maven-shade-plugin 将 JDBC 驱动打入 JAR 包内
- 标注"需手动处理"的数据库,请将对应 JDBC 驱动 JAR 放入 `plugins/` 目录
- 如果 nacos 默认 Oracle 插件与扩展 Oracle 插件冲突,只保留一个
- 切换数据库类型需要重启 nacos
DOCEOF

    log_info "配置文档: ${doc} ✓"
}

#===============================================================================
# Step 4: 打包最终发行版
#===============================================================================

package_distribution() {
    log_step "Step 4/4: 打包最终发行版"

    local final_name="nacos-xinchuang"
    if [ -n "${NACOS_VERSION}" ]; then
        final_name="${final_name}-${NACOS_VERSION}"
    fi
    local timestamp=$(date +%Y%m%d-%H%M%S)
    final_name="${final_name}-${timestamp}"

    if [ "${PLUGIN_ONLY}" = "true" ]; then
        # 仅打包插件
        mkdir -p "${OUTPUT_DIR}"
        cd "$(dirname "${OUTPUT_DIR}")"
        local archive_name="nacos-domestic-db-plugins-${timestamp}.tar.gz"
        tar -czf "${archive_name}" -C "${OUTPUT_DIR}" .
        log_info "插件包: $(pwd)/${archive_name}"
    else
        # 打包完整发行版
        cd "${NACOS_DIST_DIR}/.."
        local dist_dir_name=$(basename "${NACOS_DIST_DIR}")
        local archive_name="${final_name}.tar.gz"

        # 重命名目录
        if [ "${dist_dir_name}" != "${final_name}" ]; then
            mv "${dist_dir_name}" "${final_name}" 2>/dev/null || true
        fi

        tar -czf "${archive_name}" "${final_name}"
        log_info "==========================================="
        log_info "构建完成!"
        log_info "发行版: $(pwd)/${archive_name}"
        log_info "内容目录: $(pwd)/${final_name}"
        log_info "==========================================="

        # 显示内容摘要
        echo ""
        log_info "包含的插件 JAR:"
        ls -1 "${final_name}/plugins/" | grep -E "nacos-(dm|kingbase|opengauss|xugu|yasdb|oceanbase|mssql|oracle)" 2>/dev/null || echo "  (无)"
        echo ""
        log_info "包含的 Schema SQL:"
        ls -1 "${final_name}/conf/" | grep -E "nacos-(dm|kingbase|opengauss|xugu|yasdb|oceanbase|mssql|oracle)" 2>/dev/null || echo "  (无)"
    fi
}

#===============================================================================
# 主流程
#===============================================================================

main() {
    echo ""
    echo "=============================================="
    echo "  Nacos 信创版构建脚本"
    echo "=============================================="
    echo ""
    log_info "选择数据库: ${BUILD_DBS[*]}"
    if [ "${PLUGIN_ONLY}" != "true" ]; then
        if [ "${USE_NACOS_RELEASE}" = "true" ]; then
            log_info "Nacos 版本: ${NACOS_VERSION} (下载发行版)"
        else
            log_info "Nacos 源码: ${NACOS_SOURCE_DIR}"
        fi
    else
        log_info "模式: 仅插件"
    fi
    log_info "输出目录: ${OUTPUT_DIR}"
    echo ""

    build_plugins
    build_nacos
    copy_artifacts
    package_distribution
}

main "$@"
