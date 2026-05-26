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

readonly SESSION_COUNT=3                  # 監視セッション数
readonly SESSION_CONNECT_WAIT=30         # セッション接続待機時間（秒）
readonly SESSION_RETRY_COUNT=3           # セッション確認リトライ回数
readonly SESSION_RETRY_INTERVAL=30       # セッション確認リトライ間隔（秒）
readonly HINEMOS_CMD_TIMEOUT=60          # Hinemos・FIXエンジン制御コマンドタイムアウト（秒）

readonly LOG_FILE="/var/log/fix_failover/fix_failover_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/var/run/fix_failover.lock"

# 通知設定（メール or Slack）
readonly ALERT_MAIL="ops-team@example.com"
# readonly SLACK_WEBHOOK="<YOUR_SLACK_WEBHOOK_URL>"

# Hinemos 既存shスクリプトパス（実際のパスに変更してください）
readonly SH_MONITOR_STOP="/path/to/hinemos_monitor_stop.sh"   # TODO: 監視停止shのパス
readonly SH_MONITOR_START="/path/to/hinemos_monitor_start.sh" # TODO: 監視再開shのパス
readonly SH_JOB_STOP="/path/to/hinemos_job_stop.sh"           # TODO: ジョブ停止shのパス
readonly SH_JOB_START="/path/to/hinemos_job_start.sh"         # TODO: ジョブ再開shのパス

# FIXエンジン制御スクリプトパス（実際のパスに変更してください）
readonly SH_FIX_STOP="/path/to/fix_stop.sh"    # TODO: FIXエンジン停止スクリプトのパス
readonly SH_FIX_START="/path/to/fix_start.sh"  # TODO: FIXエンジン起動スクリプトのパス

# 監視ID（1つで3ジョブを同時監視）
readonly HINEMOS_MONITOR_ID="FIX_MONITOR_01"  # TODO: 実際の監視IDに変更

# 3つのジョブID（それぞれ個別に操作）
readonly HINEMOS_JOB_IDS=(
    "FIX_JOB_01"      # TODO: 実際のジョブID①に変更
    "FIX_JOB_02"      # TODO: 実際のジョブID②に変更
    "FIX_JOB_03"      # TODO: 実際のジョブID③に変更
)

# セッションファイルパス（3セッション分）
readonly SESSION_FILES=(
    "/opt/fix/sessions/session1.conf"
    "/opt/fix/sessions/session2.conf"
    "/opt/fix/sessions/session3.conf"
)

# セッションステータス確認コマンド（環境に合わせて変更）
readonly SESSION_STATUS_CMD="/opt/fix/bin/check_session_status.sh"

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
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }

send_alert() {
    local subject="$1"
    local body="$2"
    log_warn "アラート送信: ${subject}"
    # メール送信
    echo "${body}" | mail -s "${subject}" "${ALERT_MAIL}" 2>/dev/null || \
        log_warn "メール送信失敗（mail コマンド未設定の可能性）"
    # Slack通知（有効化する場合は SLACK_WEBHOOK を設定してコメントを外してください）
    # curl -s -X POST "${SLACK_WEBHOOK}" \
    #     -H 'Content-type: application/json' \
    #     --data "{\"text\":\"*${subject}*\n${body}\"}" || true
}

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
        exit 1
    fi
}

hinemos_stop_monitor() {
    _check_sh "${SH_MONITOR_STOP}"
    log_info "Hinemos 監視停止: ${HINEMOS_MONITOR_ID}"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_MONITOR_STOP}" "${HINEMOS_MONITOR_ID}" || {
        log_error "Hinemos 監視停止が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        exit 1
    }
    log_info "Hinemos 監視停止完了"
}

hinemos_stop_jobs() {
    _check_sh "${SH_JOB_STOP}"
    log_info "Hinemos ジョブ停止開始（3件）"
    for job_id in "${HINEMOS_JOB_IDS[@]}"; do
        log_info "  ジョブ停止: ${job_id}"
        timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_JOB_STOP}" "${job_id}" || {
            log_error "ジョブ停止が失敗またはタイムアウト: ${job_id}"
            exit 1
        }
    done
    log_info "Hinemos ジョブ停止完了"
}

hinemos_start_jobs() {
    _check_sh "${SH_JOB_START}"
    log_info "Hinemos ジョブ再開開始（3件）"
    for job_id in "${HINEMOS_JOB_IDS[@]}"; do
        log_info "  ジョブ再開: ${job_id}"
        timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_JOB_START}" "${job_id}" || {
            log_error "ジョブ再開が失敗またはタイムアウト: ${job_id}"
            exit 1
        }
    done
    log_info "Hinemos ジョブ再開完了"
}

hinemos_start_monitor() {
    _check_sh "${SH_MONITOR_START}"
    log_info "Hinemos 監視再開: ${HINEMOS_MONITOR_ID}"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_MONITOR_START}" "${HINEMOS_MONITOR_ID}" || {
        log_error "Hinemos 監視再開が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        exit 1
    }
    log_info "Hinemos 監視再開完了"
}

# -----------------------------------------------------------------------------
# FIXエンジン制御
# -----------------------------------------------------------------------------
fix_engine_stop() {
    _check_sh "${SH_FIX_STOP}"
    log_info "FIXエンジン停止開始"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_FIX_STOP}" || {
        log_error "FIXエンジン停止が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        exit 1
    }
    log_info "FIXエンジン停止完了"
}

fix_engine_start() {
    _check_sh "${SH_FIX_START}"
    log_info "FIXエンジン起動開始"
    timeout "${HINEMOS_CMD_TIMEOUT}" "${SH_FIX_START}" || {
        log_error "FIXエンジン起動が失敗またはタイムアウト（${HINEMOS_CMD_TIMEOUT}秒）"
        exit 1
    }
    log_info "FIXエンジン起動完了"
}

# -----------------------------------------------------------------------------
# 設定ファイル切替
# -----------------------------------------------------------------------------
switch_to_sub() {
    if [ ! -f "${TCPIP_SUB}" ]; then
        log_error "副系設定ファイルが存在しません: ${TCPIP_SUB}"
        exit 1
    fi
    log_info "設定ファイル切替: 正系 → 副系"
    ln -sf "${TCPIP_SUB}" "${TCPIP_LINK}"
    log_info "切替完了: ${TCPIP_LINK} -> ${TCPIP_SUB}"
}

switch_to_main() {
    if [ ! -f "${TCPIP_MAIN}" ]; then
        log_error "正系設定ファイルが存在しません: ${TCPIP_MAIN}"
        exit 1
    fi
    log_info "設定ファイル切替: 副系 → 正系"
    ln -sf "${TCPIP_MAIN}" "${TCPIP_LINK}"
    log_info "切替完了: ${TCPIP_LINK} -> ${TCPIP_MAIN}"
}

# -----------------------------------------------------------------------------
# セッション制御
# -----------------------------------------------------------------------------
place_session_files() {
    local label="${1:-}"
    log_info "セッション接続ファイル配置開始 ${label}"
    for session_file in "${SESSION_FILES[@]}"; do
        if [ -f "${session_file}" ]; then
            # ファイルをタッチして更新（再接続トリガー）
            touch "${session_file}"
            log_info "  配置完了: ${session_file}"
        else
            log_warn "  セッションファイルが見つかりません: ${session_file}"
        fi
    done
    log_info "セッションファイル配置完了。${SESSION_CONNECT_WAIT}秒待機..."
    sleep "${SESSION_CONNECT_WAIT}"
}

check_all_sessions() {
    # 戻り値: 0=全セッション正常, 1=エラーあり
    log_info "セッション接続状況確認開始"
    local error_count=0

    for i in "${!SESSION_FILES[@]}"; do
        local session_num=$((i + 1))
        # stderrをログファイルへ誘導（2>/dev/null では障害原因が消えるため）
        if "${SESSION_STATUS_CMD}" "${session_num}" 2>>"${LOG_FILE}"; then
            log_info "  セッション${session_num}: 正常"
        else
            log_warn "  セッション${session_num}: エラー"
            # ((error_count++)) は error_count=0 のとき返り値が0(偽)になり
            # set -e でスクリプトが即終了するバグがあるため算術式展開で代替する
            error_count=$((error_count + 1))
        fi
    done

    if [ "${error_count}" -eq 0 ]; then
        log_info "全セッション正常接続を確認"
        return 0
    else
        log_warn "${error_count}/${SESSION_COUNT} セッションでエラー検知"
        return 1
    fi
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
# 戻り値: 0=正系復旧成功, 1=正系でも接続不可
# -----------------------------------------------------------------------------
do_fallback_to_main() {
    log_warn "========== フェイルバック開始（副系→正系） =========="

    hinemos_stop_monitor    # ①監視停止
    hinemos_stop_jobs       # ②ジョブ停止
    fix_engine_stop
    switch_to_main
    fix_engine_start
    hinemos_start_jobs      # ③ジョブ再開
    hinemos_start_monitor   # ④監視再開

    # フェイルバック後のセッション確認（メインフェイルオーバーと同様の手順）
    place_session_files "(正系フェイルバック後)"
    if check_sessions_with_retry; then
        log_info "正系セッション正常接続確認。フェイルバック完了。"
        send_alert \
            "[復旧] FIX Engine 正系フェイルバック完了" \
            "$(date): 副系接続不可のため正系へフェイルバックしました。\nログ: ${LOG_FILE}"
        log_warn "========== フェイルバック完了（正系稼働中） =========="
        return 0
    fi

    # 正系でも接続不可：STへ問い合わせが必要
    log_error "正系・副系ともに接続不可。STへ問い合わせが必要です。"
    send_alert \
        "[緊急] FIX Engine 正系・副系ともに接続不可" \
        "$(date): 正系・副系ともに接続できませんでした。\nログ: ${LOG_FILE}\nSTへの問い合わせを実施してください。"
    log_warn "========== フェイルバック完了（要対応） =========="
    return 1
}

# -----------------------------------------------------------------------------
# メイン処理
# -----------------------------------------------------------------------------
main() {
    log_info "========== FIX自動フェイルオーバー開始 =========="

    acquire_lock

    # --------------------------------------------------
    # ステップ①：エラー検知はスクリプト呼び出し元（Hinemos監視）で実施済み想定
    # 本スクリプト起動＝エラー検知済みとして処理開始
    # --------------------------------------------------
    log_info "ステップ①：エラー検知済み（Hinemos監視による検知）"

    # --------------------------------------------------
    # ステップ②：セッション接続ファイル配置（再接続試行）
    # --------------------------------------------------
    log_info "ステップ②：セッション接続ファイル配置（再接続試行）"
    place_session_files "(初回)"

    # --------------------------------------------------
    # ステップ③：セッション接続状況確認
    # --------------------------------------------------
    log_info "ステップ③：セッション接続状況確認"
    if check_sessions_with_retry; then
        log_info "セッション正常回復。処理終了（フェイルオーバー不要）。"
        exit 0
    fi

    log_warn "セッションエラー継続。フェイルオーバー処理へ移行。"
    send_alert \
        "[警告] FIX Engine フェイルオーバー開始" \
        "$(date): セッションエラーが継続しています。正系→副系切替を開始します。\nログ: ${LOG_FILE}"

    # --------------------------------------------------
    # ステップ④：Hinemos 監視停止
    # --------------------------------------------------
    log_info "ステップ④：Hinemos 監視停止"
    hinemos_stop_monitor

    # --------------------------------------------------
    # ステップ⑤：FIX系ジョブ停止（3件）
    # --------------------------------------------------
    log_info "ステップ⑤：FIX系ジョブ停止（3件）"
    hinemos_stop_jobs

    # --------------------------------------------------
    # ステップ⑥：FIXエンジン停止
    # --------------------------------------------------
    log_info "ステップ⑥：FIXエンジン停止"
    fix_engine_stop

    # --------------------------------------------------
    # ステップ⑦：設定ファイル切替（正系→副系）
    # --------------------------------------------------
    log_info "ステップ⑦：設定ファイル切替（正系→副系）"
    switch_to_sub

    # --------------------------------------------------
    # ステップ⑧：FIXエンジン起動
    # --------------------------------------------------
    log_info "ステップ⑧：FIXエンジン起動"
    fix_engine_start

    # --------------------------------------------------
    # ステップ⑨：FIX系ジョブ再開（3件）
    # --------------------------------------------------
    log_info "ステップ⑨：FIX系ジョブ再開（3件）"
    hinemos_start_jobs

    # --------------------------------------------------
    # ステップ⑩：Hinemos 監視再開
    # --------------------------------------------------
    log_info "ステップ⑩：Hinemos 監視再開"
    hinemos_start_monitor

    # --------------------------------------------------
    # ステップ⑪：セッション接続ファイル配置（副系）
    # --------------------------------------------------
    log_info "ステップ⑪：セッション接続ファイル配置（副系向け）"
    place_session_files "(副系切替後)"

    # --------------------------------------------------
    # ステップ⑫：セッション接続状況確認
    # --------------------------------------------------
    log_info "ステップ⑫：セッション接続状況確認（副系）"
    if check_sessions_with_retry; then
        log_info "副系セッション正常接続確認。フェイルオーバー完了。"
        send_alert \
            "[復旧] FIX Engine 副系切替完了" \
            "$(date): 正系→副系切替が正常に完了しました。\nログ: ${LOG_FILE}"
        log_info "========== FIX自動フェイルオーバー正常終了 =========="
        exit 0
    fi

    # --------------------------------------------------
    # 副系も失敗：フェイルバック（副系→正系）
    # --------------------------------------------------
    if do_fallback_to_main; then
        log_info "========== FIX自動フェイルオーバー終了（正系フェイルバック完了） =========="
        exit 1  # 副系フェイルオーバー失敗・正系復旧済み（モニタリング継続）
    fi

    log_info "========== FIX自動フェイルオーバー終了（要対応） =========="
    exit 2  # 異常終了コード（STへ問い合わせ必要）
}

main "$@"
