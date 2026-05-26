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
readonly ERROR_THRESHOLD=3               # エラー判定閾値（回数）
readonly ERROR_TIME_WINDOW=300           # エラー検知時間窓（秒）
readonly SESSION_CONNECT_WAIT=30         # セッション接続待機時間（秒）
readonly SESSION_RETRY_COUNT=3           # セッション確認リトライ回数
readonly SESSION_RETRY_INTERVAL=30       # セッション確認リトライ間隔（秒）

readonly LOG_FILE="/var/log/fix_failover/fix_failover_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/var/run/fix_failover.lock"

# 通知設定（メール or Slack）
readonly ALERT_MAIL="ops-team@example.com"
# readonly SLACK_WEBHOOK="https://hooks.slack.com/services/xxx/yyy/zzz"

# Hinemos 既存shスクリプトパス（実際のパスに変更してください）
readonly SH_MONITOR_STOP="/path/to/hinemos_monitor_stop.sh"   # TODO: 監視停止shのパス
readonly SH_MONITOR_START="/path/to/hinemos_monitor_start.sh" # TODO: 監視再開shのパス
readonly SH_JOB_STOP="/path/to/hinemos_job_stop.sh"           # TODO: ジョブ停止shのパス
readonly SH_JOB_START="/path/to/hinemos_job_start.sh"         # TODO: ジョブ再開shのパス

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
    # Slack通知（有効化する場合はコメントを外す）
    # curl -s -X POST "${SLACK_WEBHOOK}" \
    #     -H 'Content-type: application/json' \
    #     --data "{\"text\":\"*${subject}*\n${body}\"}" || true
}

# -----------------------------------------------------------------------------
# 排他制御
# -----------------------------------------------------------------------------
acquire_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        local pid
        pid=$(cat "${LOCK_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            log_error "別プロセスが実行中です (PID: ${pid})。終了します。"
            exit 1
        fi
        log_warn "古いロックファイルを削除します。"
        rm -f "${LOCK_FILE}"
    fi
    echo $$ > "${LOCK_FILE}"
    log_info "ロック取得 (PID: $$)"
}

release_lock() {
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
    "${SH_MONITOR_STOP}" "${HINEMOS_MONITOR_ID}"
    log_info "Hinemos 監視停止完了"
}

hinemos_stop_jobs() {
    _check_sh "${SH_JOB_STOP}"
    log_info "Hinemos ジョブ停止開始（3件）"
    for job_id in "${HINEMOS_JOB_IDS[@]}"; do
        log_info "  ジョブ停止: ${job_id}"
        "${SH_JOB_STOP}" "${job_id}"
    done
    log_info "Hinemos ジョブ停止完了"
}

hinemos_start_jobs() {
    _check_sh "${SH_JOB_START}"
    log_info "Hinemos ジョブ再開開始（3件）"
    for job_id in "${HINEMOS_JOB_IDS[@]}"; do
        log_info "  ジョブ再開: ${job_id}"
        "${SH_JOB_START}" "${job_id}"
    done
    log_info "Hinemos ジョブ再開完了"
}

hinemos_start_monitor() {
    _check_sh "${SH_MONITOR_START}"
    log_info "Hinemos 監視再開: ${HINEMOS_MONITOR_ID}"
    "${SH_MONITOR_START}" "${HINEMOS_MONITOR_ID}"
    log_info "Hinemos 監視再開完了"
}

# -----------------------------------------------------------------------------
# FIXエンジン制御
# -----------------------------------------------------------------------------
fix_engine_stop() {
    log_info "FIXエンジン停止開始"
    # ※実際の停止コマンドに置き換えてください
    # systemctl stop fix-engine
    # または: /opt/fix/bin/fix_stop.sh
    log_info "FIXエンジン停止完了"
}

fix_engine_start() {
    log_info "FIXエンジン起動開始"
    # systemctl start fix-engine
    # または: /opt/fix/bin/fix_start.sh
    log_info "FIXエンジン起動完了"
}

# -----------------------------------------------------------------------------
# 設定ファイル切替
# -----------------------------------------------------------------------------
switch_to_sub() {
    log_info "設定ファイル切替: 正系 → 副系"
    ln -sf "${TCPIP_SUB}" "${TCPIP_LINK}"
    log_info "切替完了: ${TCPIP_LINK} -> ${TCPIP_SUB}"
}

switch_to_main() {
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
        if "${SESSION_STATUS_CMD}" "${session_num}" 2>/dev/null; then
            log_info "  セッション${session_num}: 正常"
        else
            log_warn "  セッション${session_num}: エラー"
            ((error_count++))
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

    log_error "正系・副系ともに接続不可。STへ問い合わせが必要です。"
    send_alert \
        "[緊急] FIX Engine 正系・副系ともに接続不可" \
        "$(date): 正系・副系ともに接続できませんでした。\nログ: ${LOG_FILE}\nSTへの問い合わせを実施してください。"

    log_warn "========== フェイルバック完了 =========="
}

# -----------------------------------------------------------------------------
# メイン処理
# -----------------------------------------------------------------------------
main() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    log_info "========== FIX自動フェイルオーバー開始 =========="

    acquire_lock

    # --------------------------------------------------
    # ステップ①：エラー検知はスクリプト呼び出し元（Hinemos監視）で実施済み想定
    # 本スクリプト起動＝エラー検知済みとして処理開始
    # --------------------------------------------------
    log_info "ステップ①：エラー検知済み（閾値: ${ERROR_THRESHOLD}回 / ${ERROR_TIME_WINDOW}秒以内）"

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
    # ステップ④⑤：監視停止→ジョブ停止→エンジン停止
    # --------------------------------------------------
    log_info "ステップ④：Hinemos 監視停止（3件）"
    hinemos_stop_monitor

    log_info "ステップ⑤：FIX系ジョブ停止（3件）"
    hinemos_stop_jobs

    log_info "ステップ⑥：FIXエンジン停止"
    fix_engine_stop

    # --------------------------------------------------
    # ステップ⑦：設定ファイル切替（正系→副系）
    # --------------------------------------------------
    log_info "ステップ⑦：設定ファイル切替（正系→副系）"
    switch_to_sub

    # --------------------------------------------------
    # ステップ⑧⑨⑩：エンジン起動→ジョブ再開→監視再開
    # --------------------------------------------------
    log_info "ステップ⑧：FIXエンジン起動"
    fix_engine_start

    log_info "ステップ⑨：FIX系ジョブ再開（3件）"
    hinemos_start_jobs

    log_info "ステップ⑩：Hinemos 監視再開（3件）"
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
    do_fallback_to_main

    log_info "========== FIX自動フェイルオーバー終了（要対応） =========="
    exit 2  # 異常終了コード（STへ問い合わせ必要）
}

main "$@"
