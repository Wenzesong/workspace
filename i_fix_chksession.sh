COMMAND="ls -l /var/script/inf/lib/fxds_common_lib.sh > /dev/null 2>&1"
eval ${COMMAND}
RESULT_CODE=$?

if [ ${RESULT_CODE} -ne 0 ];then
    G_CALLER_SHELL_NAME="$(basename ${0})"
    ERROR_MESSAGE="$(echo "000010E 共通ライブラリが存在しません。ファイルパス：[/var/script/inf/bin/fxds_comon_lib.sh]")"
    echo "${ERROR_MESSAGE}"
    logger -t "ERROR" -p user.error "${ERROR_MESSAGE}"

    ERROR_MESSAGE="$(echo "000002E スクリプトの実行に失敗しました。終了コード：[81] スクリプト名：["${G_CALLER_SHELL_NAME}"]")"
    echo "${ERROR_MESSAGE}"
    logger -t "ERROR" -p user.error "${ERROR_MESSAGE}"

    exit 8
else
    :
fi

# 共通関数読み込み
. /var/script/inf/lib/fxds_common_lib.sh

# 1-2．開始メッセージ出力
G_COMMON_MESSAGE 000000I ${G_CALLER_SHELL_NAME}

# スクリプト内関数言
export FX_CMD_SERVICE=20000

#$1.設定ファイル読み込み関数
###i_fix_ctr1.listが設定ファイル、設定ファイルの存在チェック、あれば次の処理、無ければエラーを出して終了

function L_READ_CONF
{
    ## 設定ファイル判定、ホスト名・設定ファイル名については環境ごとに記載を分ける。
    CONFIG_FILE="${G_CALLER_SHELL_NAME/%???/}.list"
    ## 設定ファイル存在確認
    COMMAND="${LS} -l ${GSCRIPT_CONF_DIR}${CONFIG_FILE}"
    ${EVAL} ${COMMAND} > /dev/null 2>&1
    ## 設定ファイルが存在しなければ終了
    if [ $? -ne 0 ]; then
        ## メッセージ：設定ファイルが存在しません
        G_COMMON_MESSAGE 017000E ${CONFIG_FILE}

        ## 終了コードを終了関数に渡す
        G_SHELL_FINISH "${G_FAILURE_CODE}"
    
    ## 設定ファイルが存在すれば次の処理
    else
        :
    fi 
}

#S2.セッション状態確認
function L_SESSION_STATUS_CHECK
{
    ERROR_FLG=0
    while read LINE
    do
        ######先頭文字が＃の場合スキップする
        if [ "$(${ECHO} ${LINE} | ${CUT} -c 1)" = "#" ]; then
            continue
        else
            :
        fi

        if [ "${LINE}" = "all" ]; then
            # allの場合、全パス確認
            COMMAND="${CTLEXSVC} report"
            GREP_COMMAND="${CTLEXSVC} report | ${GREP} 'FIX not established'"
        else
            #複数パスなら個別確認
            PATHNAME=${LINE}
            COMMAND="${CTLEXSVC} report -p ${PATHNAME} -C ${FX_CMD_SERVICE}"
            GREP_COMMAND="${CTLEXSVC} report -p ${PATHNAME} -C ${FX_CMD_SERVICE} | ${GREP} 'FIX not established'"
        fi
        
        #セッション状態の取得が成功するか確認
        ${EVAL} ${COMMAND} > /dev/null 2>&1
        RTNCODE=$?
        if [ $RTNCODE -ne 0 ]; then
            # コマンドが失敗した場合
            G_COMMON_MESSAGE 017010E "${COMMAND}" ${RTNCODE}
            G_SHELL_FINISH "${G_FAILURE_CODE}"
        else
            # コマンドが成功した場合
            :
        fi

        ${EVAL} ${GREP_COMMAND} > /dev/null 2>&1
        RTNCODE=$?
        if [ $RTNCODE -eq 1 ]; then
            # fix not establishedがない場合
            G_COMMON_MESSAGE 017020I "${LINE}"
        else
            # fix not establishedがある場合
            G_COMMON_MESSAGE 017021E "${LINE}"
            ERROR_FLG=8
            :
        fi
    done < ${GSCRIPT_CONF_DIR}${CONFIG_FILE}
}

# 設定ファイル確認
L_READ_CONF "$1"

L_SESSION_STATUS_CHECK

# セッション接続失敗時：フェイルオーバースクリプト実行
FIX_FAILOVER_SH="/var/script/inf/bin/fix_failover.sh"
if [ "${ERROR_FLG}" -ne 0 ]; then
    if [ ! -x "${FIX_FAILOVER_SH}" ]; then
        ERROR_MESSAGE="$(echo "フェイルオーバースクリプトが見つかりません: [${FIX_FAILOVER_SH}]")"
        echo "${ERROR_MESSAGE}"
        logger -t "ERROR" -p user.error "${ERROR_MESSAGE}"
        G_SHELL_FINISH "${G_FAILURE_CODE}"
    fi
    "${FIX_FAILOVER_SH}"
    ERROR_FLG=$?
fi

# 終了処理
G_SHELL_FINISH "${ERROR_FLG}"

