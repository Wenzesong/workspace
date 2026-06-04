#!/bin/bash
# =============================================================================
# FIX Engine 自動フェイルオーバースクリプト
# 正系→副系切替、および副系→正系フェイルバック
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 設定値（環境に合わせて変更してください）
# -----------------------------------------------------------------------------
readonly TCPIP_MAIN="/opt/fix/env/line/tcpip_main"
readonly TCPIP_SUB="/opt/fix/env/line/tcpip_sub"
readonly TCPIP_LINK="/opt/fix/env/line/tcpip"

readonly SESSION_CONNECT_WAIT=30         # セッション接続待機時間（秒）
readonly SESSION_RETRY_COUNT=3           # セッション確認リトライ回数
readonly SESSION_RETRY_INTERVAL=30       # セッション確認リトライ間隔（秒）
readonly HINEMOS_CMD_TIMEOUT=60          # Hinemos・FIXエンジン制御コマンドタイムアウト（秒）

readonly LOG_FILE="/var/log/fix_failover/fix_failover_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/var/run/fix_failover.lock"

# 制御スクリプトパス（引数は各関数内で指定）
readonly SH_MONITOR_CTRL="/var/script/inf/bin/i_hin_ctrlmonitor_ids.sh"
readonly SH_JOB_CTRL="/var/script/inf/bin/i_jar_ctrl.sh"
readonly SH_FIX_CTRL="/var/script/inf/bin/i_fix_ctrl.sh"

# FIXセッション監視ID
readonly HINEMOS_MONITOR_ID="S0B1_DEV_FXDS_FIX_SESSION" 

# FIXセッション接続要求（スクリプトパス + 引数）
readonly -a FIX_CONNECT_STR=("/var/script/ap1/APLJB_FixConnect.sh" "jbstr0001")
readonly -a FIX_CONNECT_ORD=("/var/script/ap1/APLJB_FixConnect.sh" "jbord0002")
readonly -a FIX_CONNECT_STP=("/var/script/ap1/APLJB_FixConnect.sh" "jbstp0002")

# セッション確認リスト
readonly SESSION_LIST_FILE="/var/script/inf/conf/i_fix_chksession.list"
readonly FX_CMD_SERVICE=20000

# -----------------------------------------------------------------------------
# ログディレクトリ事前作成（trapより前に実施してtrap内のlog_infoを保証する）
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")"

# -----------------------------------------------------------------------------
# ログ・通知関数
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
    case "${level}" in
        "ERROR") logger -t "ERROR" -p user.error   "${message}" ;;
        "WARN ") logger -t "WARN"  -p user.warning "${message}" ;;
        "INFO ") logger -t "INFO"  -p user.info    "${message}" ;;
    esac
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }

# -----------------------------------------------------------------------------
# 共通ライブラリ読み込み（CTLEXSVC 等の変数を取得）
# -----------------------------------------------------------------------------
readonly COMMON_LIB="/var/script/inf/lib/fxds_common_lib.sh"
if [ ! -f "${COMMON_LIB}" ]; then
    log_error "共通ライブラリが見つかりません: ${COMMON_LIB}"
    exit 1
fi
. "${COMMON_LIB}"
G_CALLER_SHELL_NAME="$(basename "${0}")"

# -----------------------------------------------------------------------------
# 排他制御（flock によるアトミックロック — TOCTOU競合を防止）
# -----------------------------------------------------------------------------
acquire_lock() {
    # fd 9 にロックファイルを紐付け。flock -n で非ブロッキング取得を試みる。
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        local pid
        pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "不明")
        log_error "別プロセスが実行中です (PID: ${pid})。終了します。"
        exit 1
    fi
    echo $$ >&9
    log_info "ロック取得 (PID: $$)"
}

release_lock() {
    flock -u 9 2>/dev/null || true
    rm -f "${LOCK_FILE}"
    log_info "ロック解放"
}

# スクリプト終了時に必ずロック解放
trap 'release_lock; log_info "スクリプト終了"' EXIT

# -----------------------------------------------------------------------------
# Hinemos 制御（既存shスクリプトを呼び出し）
# -----------------------------------------------------------------------------
_check_sh() {
    local sh_path="$1"
    if [ ! -x "${sh_path}" ]; then
        log_error "スクリプトが見つかりません: ${sh_path}"
        return 1
    fi
}

hinemos_stop_monitor() {
    _check_sh "${SH_MONITOR_CTRL}" || return 1
    log_info "Hinemos 監視停止: ${HINEMOS_MONITOR_ID}"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_MONITOR_CTRL}" stop "${HINEMOS_MONITOR_ID}" || {
        log_error "Hinemos 監視停止が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        return 1
    }
    log_info "Hinemos 監視停止完了"
}

hinemos_stop_jobs() {
    _check_sh "${SH_JOB_CTRL}" || return 1
    log_info "Hinemos ジョブ停止開始"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_JOB_CTRL}" stop FIX || {
        log_error "Hinemos ジョブ停止が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        return 1
    }
    log_info "Hinemos ジョブ停止完了"
}

hinemos_start_jobs() {
    _check_sh "${SH_JOB_CTRL}" || return 1
    log_info "Hinemos ジョブ再開開始"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_JOB_CTRL}" start FIX || {
        log_error "Hinemos ジョブ再開が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        return 1
    }
    log_info "Hinemos ジョブ再開完了"
}

hinemos_start_monitor() {
    _check_sh "${SH_MONITOR_CTRL}" || return 1
    log_info "Hinemos 監視再開: ${HINEMOS_MONITOR_ID}"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_MONITOR_CTRL}" start "${HINEMOS_MONITOR_ID}" || {
        log_error "Hinemos 監視再開が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        return 1
    }
    log_info "Hinemos 監視再開完了"
}

# -----------------------------------------------------------------------------
# FIXエンジン制御
# -----------------------------------------------------------------------------
fix_engine_stop() {
    _check_sh "${SH_FIX_CTRL}" || return 1
    log_info "FIXエンジン停止開始"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_FIX_CTRL}" stop || {
        log_error "FIXエンジン停止が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        return 1
    }
    log_info "FIXエンジン停止完了"
}

fix_engine_start() {
    _check_sh "${SH_FIX_CTRL}" || return 1
    log_info "FIXエンジン起動開始"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_FIX_CTRL}" start || {
        log_error "FIXエンジン起動が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        return 1
    }
    log_info "FIXエンジン起動完了"
}

# -----------------------------------------------------------------------------
# 設定ファイル切替
# -----------------------------------------------------------------------------
switch_to_sub() {
    if [ ! -f "${TCPIP_SUB}" ]; then
        log_error "副系設定ファイルが存在しません: ${TCPIP_SUB}"
        return 1
    fi
    local current_line
    current_line=$(get_current_line)
    if [ "${current_line}" = "sub" ]; then
        log_warn "既に副系が稼働中です。切替をスキップします。"
        return 0
    fi
    log_info "設定ファイル切替: 正系 → 副系（現在: ${current_line}）"
    ln -sf "${TCPIP_SUB}" "${TCPIP_LINK}"
    log_info "切替完了: ${TCPIP_LINK} -> ${TCPIP_SUB}"
}

switch_to_main() {
    if [ ! -f "${TCPIP_MAIN}" ]; then
        log_error "正系設定ファイルが存在しません: ${TCPIP_MAIN}"
        return 1
    fi
    local current_line
    current_line=$(get_current_line)
    if [ "${current_line}" = "main" ]; then
        log_warn "既に正系が稼働中です。切替をスキップします。"
        return 0
    fi
    log_info "設定ファイル切替: 副系 → 正系（現在: ${current_line}）"
    ln -sf "${TCPIP_MAIN}" "${TCPIP_LINK}"
    log_info "切替完了: ${TCPIP_LINK} -> ${TCPIP_MAIN}"
}

get_current_line() {
    #現在の稼働系を確認（symlinkのリンク先で判定）
    local current
    current=$(readlink "${TCPIP_LINK}" 2>/dev/null || echo "unknown")
    case "${current}" in
       *tcpip_main*) echo "main" ;;
       *tcpip_sub*)  echo "sub" ;;
       *)            echo "unknown" ;;
    esac
}

# -----------------------------------------------------------------------------
# セッション制御
# -----------------------------------------------------------------------------
place_session_files() {
    local label="${1:-}"
    log_info "セッション接続ファイル配置開始 ${label}"
    _check_sh "${FIX_CONNECT_STR[0]}" || log_warn "  STR スクリプトが見つかりません: ${FIX_CONNECT_STR[0]}"
    _check_sh "${FIX_CONNECT_ORD[0]}" || log_warn "  ORD スクリプトが見つかりません: ${FIX_CONNECT_ORD[0]}"
    _check_sh "${FIX_CONNECT_STP[0]}" || log_warn "  STP スクリプトが見つかりません: ${FIX_CONNECT_STP[0]}"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${FIX_CONNECT_STR[@]}" 2>>"${LOG_FILE}" \
        || log_warn "  STR セッション接続要求失敗"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${FIX_CONNECT_ORD[@]}" 2>>"${LOG_FILE}" \
        || log_warn "  ORD セッション接続要求失敗"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${FIX_CONNECT_STP[@]}" 2>>"${LOG_FILE}" \
        || log_warn "  STP セッション接続要求失敗"
    log_info "セッション接続要求完了。${SESSION_CONNECT_WAIT}秒待機..."
    sleep "${SESSION_CONNECT_WAIT}"
}

check_all_sessions() {
    # 戻り値: 0=1セッション以上接続確認, 1=全セッション未接続
    log_info "セッション接続状況確認開始"
    local report_out

    if [ ! -f "${SESSION_LIST_FILE}" ]; then
        log_error "セッションリストファイルが見つかりません: ${SESSION_LIST_FILE}"
        return 1
    fi

    while IFS= read -r line; do
        # コメント行・空行スキップ
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" ]] && continue

        if [ "${line}" = "all" ]; then
            if ! report_out=$(${CTLEXSVC} report 2>>"${LOG_FILE}"); then
                log_warn "  全パス: コマンド失敗"
                continue
            fi
        else
            if ! report_out=$(${CTLEXSVC} report -p "${line}" -C "${FX_CMD_SERVICE}" 2>>"${LOG_FILE}"); then
                log_warn "  ${line}: コマンド失敗"
                continue
            fi
        fi

        if ! echo "${report_out}" | grep -q 'FIX not established'; then
            log_info "  ${line}: 接続確認"
            log_info "1セッション接続確認。確認終了。"
            return 0
        else
            log_warn "  ${line}: 未接続 (FIX not established)"
        fi
    done < "${SESSION_LIST_FILE}"

    log_warn "全セッション未接続"
    return 1
}

check_sessions_with_retry() {
    # リトライ付きセッション確認
    # 戻り値: 0=成功, 1=失敗
    for attempt in $(seq 1 "${SESSION_RETRY_COUNT}"); do
        log_info "セッション確認 (試行 ${attempt}/${SESSION_RETRY_COUNT})"
        if check_all_sessions; then
            return 0
        fi
        if [ "${attempt}" -lt "${SESSION_RETRY_COUNT}" ]; then
            log_info "${SESSION_RETRY_INTERVAL}秒後に再試行..."
            sleep "${SESSION_RETRY_INTERVAL}"
        fi
    done
    log_error "全リトライ失敗: セッション接続不可"
    return 1
}

# -----------------------------------------------------------------------------
# フェイルバック処理（副系→正系へ戻す）
# 戻り値: 0=正系復旧成功, 1=制御コマンド失敗 または 正系でも接続不可
# -----------------------------------------------------------------------------
do_fallback_to_main() {
    log_warn "========== フェイルバック開始（副系→正系） =========="

    hinemos_stop_monitor    || return 1  # ①監視停止
    hinemos_stop_jobs       || return 1  # ②ジョブ停止
    fix_engine_stop         || return 1
    switch_to_main          || return 1
    fix_engine_start        || return 1
    hinemos_start_jobs      || return 1  # ③ジョブ再開
    hinemos_start_monitor   || return 1  # ④監視再開

    # フェイルバック後のセッション確認（メインフェイルオーバーと同様の手順）
    place_session_files "(正系フェイルバック後)"
    if check_sessions_with_retry; then
        log_info "正系セッション正常接続確認。フェイルバック完了。"
        log_warn "========== フェイルバック完了（正系稼働中） =========="
        return 0
    fi

    # 正系でも接続不可：STへ問い合わせが必要
    log_error "正系・副系ともに接続不可。STへ問い合わせが必要です。"
    log_warn "========== フェイルバック完了（要対応） =========="
    return 1
}

# -----------------------------------------------------------------------------
# メイン処理
# -----------------------------------------------------------------------------
main() {
    G_COMMON_MESSAGE 000000I "${G_CALLER_SHELL_NAME}"
    log_info "========== FIX自動フェイルオーバー開始 =========="

    acquire_lock

    # --------------------------------------------------
    # ステップ1：エラー検知はスクリプト呼び出し元（Hinemos監視）で実施済み想定
    # 本スクリプト起動＝エラー検知済みとして処理開始
    # --------------------------------------------------
    log_info "ステップ1：エラー検知済み（Hinemos監視による検知）"
    log_info "現在の稼働系: $(get_current_line)"

    # --------------------------------------------------
    # ステップ2：セッション接続ファイル配置（再接続試行）
    # --------------------------------------------------
    log_info "ステップ2：セッション接続ファイル配置（再接続試行）"
    place_session_files "(初回)"

    # --------------------------------------------------
    # ステップ3：セッション接続状況確認
    # --------------------------------------------------
    log_info "ステップ3：セッション接続状況確認"
    if check_sessions_with_retry; then
        log_info "セッション正常回復。処理終了（フェイルオーバー不要）。"
        exit 0
    fi

    log_warn "セッションエラー継続。フェイルオーバー処理へ移行。"

    # --------------------------------------------------
    # 副系スタートの場合：フェイルオーバーをスキップして正系へ直接フェイルバック
    # --------------------------------------------------
    if [ "$(get_current_line)" = "sub" ]; then
        log_warn "副系稼働中にセッションエラーを検知。正系へフェイルバックします。"
        if do_fallback_to_main; then
            log_info "========== FIX自動フェイルオーバー終了（正系フェイルバック完了） =========="
            exit 0
        fi
        log_info "========== FIX自動フェイルオーバー終了（要対応） =========="
        exit 2
    fi

    # --------------------------------------------------
    # ステップ4：Hinemos 監視停止
    # --------------------------------------------------
    log_info "ステップ4：Hinemos 監視停止"
    hinemos_stop_monitor

    # --------------------------------------------------
    # ステップ5：FIX系ジョブ停止（3件）
    # --------------------------------------------------
    log_info "ステップ5：FIX系ジョブ停止（3件）"
    hinemos_stop_jobs

    # --------------------------------------------------
    # ステップ6：FIXエンジン停止
    # --------------------------------------------------
    log_info "ステップ6：FIXエンジン停止"
    fix_engine_stop

    # --------------------------------------------------
    # ステップ7：設定ファイル切替（正系→副系）
    # --------------------------------------------------
    log_info "ステップ7：設定ファイル切替（正系→副系）"
    switch_to_sub

    # --------------------------------------------------
    # ステップ8：FIXエンジン起動
    # --------------------------------------------------
    log_info "ステップ8：FIXエンジン起動"
    fix_engine_start

    # --------------------------------------------------
    # ステップ9：FIX系ジョブ再開（3件）
    # --------------------------------------------------
    log_info "ステップ9：FIX系ジョブ再開（3件）"
    hinemos_start_jobs

    # --------------------------------------------------
    # ステップ10：Hinemos 監視再開
    # --------------------------------------------------
    log_info "ステップ10：Hinemos 監視再開"
    hinemos_start_monitor

    # --------------------------------------------------
    # ステップ11：セッション接続ファイル配置（副系）
    # --------------------------------------------------
    log_info "ステップ11：セッション接続ファイル配置（副系向け）"
    place_session_files "(副系切替後)"

    # --------------------------------------------------
    # ステップ12：セッション接続状況確認
    # --------------------------------------------------
    log_info "ステップ12：セッション接続状況確認（副系）"
    if check_sessions_with_retry; then
        log_info "副系セッション正常接続確認。フェイルオーバー完了。"
        log_info "========== FIX自動フェイルオーバー正常終了 =========="
        exit 0
    fi

    # --------------------------------------------------
    # 副系も失敗：フェイルバック（副系→正系）
    # --------------------------------------------------
    if do_fallback_to_main; then
        log_info "========== FIX自動フェイルオーバー終了（正系フェイルバック完了） =========="
        exit 0
    fi

    log_info "========== FIX自動フェイルオーバー終了（要対応） =========="
    exit 2  # 異常終了コード（STへ問い合わせ必要）
}

main "$@"
