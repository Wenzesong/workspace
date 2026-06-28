package jp.co.daiwa.jbpos1100.file;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.springframework.batch.core.StepContribution;

import jp.co.daiwa.base.LogBatchBasedLogger;
import jp.co.daiwa.common.DateUtil;
import jp.co.daiwa.common.FileUtil;
import jp.co.daiwa.common.constant.FxdConstants;
import jp.co.daiwa.dao.bean.TByCcyDeltaCashBalanceBean;
import jp.co.daiwa.dao.bean.TPositionSpotSumDataBean;
import jp.co.daiwa.dao.bean.TPositionSwapSumDataBean;
import jp.co.daiwa.dao.bean.TSwapPlSumDateBean;
import jp.co.daiwa.jbpos1100.common.EvaluationRateNames;
import jp.co.daiwa.jbpos1100.common.JobWarningReporter;

/**
 * {@link PositionSumFileWriter} の既定実装。
 *
 * <p>旧 {@code jp.co.daiwa.jbpos1000.Jbpos1000PositionSumDateFileUtil}（static ユーティリティ）の
 * ファイル出力ロジックを jbpos1100 側へ移植したもの。jbpos1000 への依存は持たない。</p>
 *
 * <p>移植時の改善点（出力内容は旧実装とバイト等価を維持）:</p>
 * <ul>
 *   <li>1 行あたり十数回繰り返していた {@code sb.append(値); sb.append(KEY_TAB);} の定型を
 *       {@link #toTsvLine(Object...)} に集約（タブ区切り組立を 1 箇所に）。</li>
 *   <li>レート区分名の解決を {@link EvaluationRateNames} に統一（jbpos1100 全体の規約に合わせる）。</li>
 *   <li>例外時のジョブ警告状態設定を {@link JobWarningReporter#markJobWarning()} に委譲し、
 *       {@code ExecutionContext} への直接 put（長い getter チェーン）を排除。</li>
 *   <li>明細組立を区分ごとの private メソッドに分割し、責務を可視化。</li>
 * </ul>
 *
 * <p>Spring からは引数なしで生成される（{@code jbpos1100.xml} の bean 定義）。状態は持たず、
 * 警告レポータは呼び出し時の {@link StepContribution} から都度生成する。</p>
 */
public class DefaultPositionSumFileWriter implements PositionSumFileWriter {

    /** ポジションスポット集計ファイル名プレフィックス。 */
    private static final String SPOT_FILE_PREFIX = "position_spot_sum_";
    /** ポジションスワップ集計ファイル名プレフィックス。 */
    private static final String SWAP_FILE_PREFIX = "position_swap_sum_";
    /** 計算エラーメッセージ。 */
    private static final String CALC_ERR = "計算エラー";
    /** TSV ファイル拡張子。 */
    private static final String FILE_TSV = ".tsv";

    private static final LogBatchBasedLogger logger =
            LogBatchBasedLogger.getLogger(DefaultPositionSumFileWriter.class);

    @Override
    public void writeSpotSumFile(StepContribution contribution, String outputFilePath, String evaluationRateKbn,
            List<TPositionSpotSumDataBean> spotSumList) {
        String filename = outputFilePath + SPOT_FILE_PREFIX + EvaluationRateNames.of(evaluationRateKbn) + FILE_TSV;
        List<List<String>> fileData = new ArrayList<>();
        try {
            for (TPositionSpotSumDataBean item : spotSumList) {
                fileData.add(buildSpotRow(item));
            }
            FileUtil.writeTsvFile(filename, fileData);
        } catch (Exception e) {
            logger.warn("DefaultPositionSumFileWriter.writeSpotSumFile", "ポジションスポット集計ファイル出力",
                    "MSG_J_W002", e);
            // ジョブ警告状態を設定
            new JobWarningReporter(contribution).markJobWarning();
        }
    }

    @Override
    public void writeSwapSumFile(StepContribution contribution, String outputFilePath, String evaluationRateKbn,
            List<TSwapPlSumDateBean> plSumList, List<TByCcyDeltaCashBalanceBean> deltaCashList,
            List<TPositionSwapSumDataBean> currencySumList) {
        String filename = outputFilePath + SWAP_FILE_PREFIX + EvaluationRateNames.of(evaluationRateKbn) + FILE_TSV;
        List<List<String>> fileData = new ArrayList<>();
        try {
            // 1. スワップ PL 合計
            for (TSwapPlSumDateBean item : plSumList) {
                fileData.add(buildSwapPlRow(item));
            }
            fileData.add(blankLine());
            // 2. 通貨別デルタ・キャッシュ残
            for (TByCcyDeltaCashBalanceBean item : deltaCashList) {
                fileData.add(buildDeltaCashRow(item));
            }
            fileData.add(blankLine());
            // 3. 通貨単位纏めスワップ集計
            for (TPositionSwapSumDataBean item : currencySumList) {
                fileData.add(buildSwapCurrencyRow(item));
            }
            FileUtil.writeTsvFile(filename, fileData);
        } catch (Exception e) {
            logger.warn("DefaultPositionSumFileWriter.writeSwapSumFile", "ポジションスワップ集計ファイル出力",
                    "MSG_J_W002", e);
            // ジョブ警告状態を設定
            new JobWarningReporter(contribution).markJobWarning();
        }
    }

    /**
     * スポット集計 1 明細行を組み立てる（旧 writePostSumDateFile の列順を踏襲）。
     */
    private static List<String> buildSpotRow(TPositionSpotSumDataBean item) {
        return toTsvLine(
                // 実行日
                DateUtil.convertDateToStrYmdSlash(item.getProcessBaseDate()),
                // ディーラブック
                item.getDealerBook(),
                // 通貨ペア
                item.getCurrencyPair(),
                // Real評価レート(ストリーミングレート)
                item.getRealRate(),
                // 引値評価レート
                item.getClosingRate(),
                // マニュアル(日中時価評価レート)
                item.getManualDailyRate(),
                // マニュアル(引けレート、TTM)
                item.getManualClosingTtmRate(),
                // Avgコストレート
                item.getAvgCostRate(),
                // 評価ポジション
                item.getEvaluationPosition(),
                // 評価PL(円換算)
                item.getEvaluationPlYenConversion() == null ? CALC_ERR : item.getEvaluationPlYenConversion(),
                // 累積確定PL(円換算)
                item.getSumPlYenConversion(),
                // 合計PL額
                item.getSumPlYen() == null ? CALC_ERR : item.getSumPlYen(),
                // 前日繰越
                item.getBeforeEvaluationPosition(),
                // ネット増減
                item.getNetIncreaseOrDecrease(),
                // 更新者
                item.getUpdateUser(),
                // 更新日時
                new Timestamp(System.currentTimeMillis()));
    }

    /**
     * スワップ PL 合計 1 明細行を組み立てる。
     */
    private static List<String> buildSwapPlRow(TSwapPlSumDateBean item) {
        return toTsvLine(
                // 実行日
                DateUtil.convertDateToStrYmdSlash(item.getProcessBaseDate()),
                // ディーラブック
                item.getDealerBook(),
                // PL合計値
                item.getPlTotal() == null ? CALC_ERR : item.getPlTotal());
    }

    /**
     * 通貨別デルタ・キャッシュ残 1 明細行を組み立てる。
     */
    private static List<String> buildDeltaCashRow(TByCcyDeltaCashBalanceBean item) {
        return toTsvLine(
                // 実行日
                DateUtil.convertDateToStrYmdSlash(item.getProcessBaseDate()),
                // ディーラブック
                item.getDealerBook(),
                // 通貨
                item.getCurrency(),
                // Delta
                item.getDelta() == null ? CALC_ERR : item.getDelta(),
                // キャッシュ残
                item.getCashBalance() == null ? BigDecimal.ZERO : item.getCashBalance());
    }

    /**
     * 通貨単位纏めスワップ集計 1 明細行を組み立てる。
     */
    private static List<String> buildSwapCurrencyRow(TPositionSwapSumDataBean item) {
        return toTsvLine(
                // 処理基準日
                DateUtil.convertDateToStrYmdSlash(item.getProcessBaseDate()),
                // ディーラブック
                item.getDealerBook(),
                // 通貨
                item.getCurrency(),
                // 受渡日
                DateUtil.convertDateToStrYmdSlash(item.getDeliveryDate()),
                // CF金額
                item.getCashAmount());
    }

    /**
     * 可変長フィールドをタブ区切りで連結し、1 行分（要素 1 個のリスト）として返す。
     *
     * <p>各フィールドは {@code StringBuilder#append(Object)} と同一の文字列化規則
     * （{@code null} は文字列 {@code "null"}）で連結され、旧実装と出力が一致する。</p>
     *
     * @param fields 出力フィールド（左から順に並べる）
     * @return タブ連結済み文字列 1 個を要素に持つ可変リスト
     */
    private static List<String> toTsvLine(Object... fields) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < fields.length; i++) {
            if (i > 0) {
                sb.append(FxdConstants.KEY_TAB);
            }
            sb.append(fields[i]);
        }
        List<String> line = new ArrayList<>();
        line.add(sb.toString());
        return line;
    }

    /**
     * 区分間の区切りとなる空行を返す（旧実装の {@code Arrays.asList("")} 相当）。
     */
    private static List<String> blankLine() {
        return Arrays.asList("");
    }
}
