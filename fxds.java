DB更新は同期、Samba書き込みは非同期で分離する。

例：
受信 → 電文キュー → 電文Worker（2スレッド）
                          │
                          ├─ 取引管理テーブル更新
                          └─ 条件OK → リーブオーダー管理テーブル更新
                          │
                          └─ Sambaキューに投入
                                    │
                               Samba Worker（4スレッド）
                                    │
                         取引管理ファイル・応答ファイル・リーブオーダー+ユーザー通知ファイル（条件OK） 書き込み


@Component
public class MessageProcessingTasklet implements Tasklet {

    @Inject
    private ATableRepository aTableRepository;
    @Inject
    private CTableRepository cTableRepository;

    // 电文队列
    private final BlockingQueue<Message> messageQueue =
        new LinkedBlockingQueue<>(1000);

    // Samba写入队列（A文件、B文件、C文件まとめて）
    private final BlockingQueue<SambaTask> sambaQueue =
        new LinkedBlockingQueue<>(1000);

    private final ExecutorService messagePool =
        Executors.newFixedThreadPool(8);
    private final ExecutorService sambaPool =
        Executors.newFixedThreadPool(20);

    @Override
    public RepeatStatus execute(StepContribution contribution,
                                ChunkContext chunkContext) throws Exception {

        // 1. 电文Worker起动
        for (int i = 0; i < 8; i++) {
            messagePool.submit(() -> {
                while (!Thread.currentThread().isInterrupted()) {
                    try {
                        Message msg = messageQueue.take();
                        processMessage(msg);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
            });
        }

        // 2. Samba Worker起动
        for (int i = 0; i < 20; i++) {
            sambaPool.submit(() -> {
                while (!Thread.currentThread().isInterrupted()) {
                    try {
                        SambaTask task = sambaQueue.take();
                        writeSamba(task);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
            });
        }

        // 3. 接收电文，投入队列
        List<Message> incoming = fetchIncomingMessages();
        for (Message msg : incoming) {
            messageQueue.offer(msg);
        }

        // 4. 等待全部处理完
        waitForQueueEmpty(messageQueue);
        waitForQueueEmpty(sambaQueue);

        messagePool.shutdownNow();
        sambaPool.shutdownNow();

        return RepeatStatus.FINISHED;
    }

    private void processMessage(Message msg) {
        // 固定条件チェック
        if (!meetsCriteria(msg)) return;

        // ① A表更新（无条件）
        aTableRepository.update(msg);

        // A表写入Samba队列（A文件 + B文件）
        sambaQueue.offer(new SambaTask(msg, SambaTaskType.A_FILE));
        sambaQueue.offer(new SambaTask(msg, SambaTaskType.B_FILE));

        // ② A表状态确认 → 条件满足时做C表
        AStatus status = aTableRepository.findStatus(msg.getId());
        if (status.needsCProcess()) {
            cTableRepository.update(msg);

            // C文件×2
            sambaQueue.offer(new SambaTask(msg, SambaTaskType.C_FILE_1));
            sambaQueue.offer(new SambaTask(msg, SambaTaskType.C_FILE_2));
        }
    }

    private void writeSamba(SambaTask task) {
        // タスク种类によってパス切り替え
        Path path = switch (task.getType()) {
            case A_FILE  -> Path.of("\\\\server\\share\\A\\", task.getFileName());
            case B_FILE  -> Path.of("\\\\server\\share\\B\\", task.getFileName());
            case C_FILE_1 -> Path.of("\\\\server\\share\\C1\\", task.getFileName());
            case C_FILE_2 -> Path.of("\\\\server\\share\\C2\\", task.getFileName());
        };
        Files.write(path, task.getContent());
    }
}

 