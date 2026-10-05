import '../domain/ledger_models.dart';
import 'sqlite_ledger_repository.dart';
export '../domain/ledger_models.dart';

abstract class LedgerRepository {
  static Future<LedgerRepository> open({String? path, String? workspace}) =>
      SqliteLedgerRepository.connect(path: path, workspace: workspace);
  Future<void> close();
  Stream<int> get changes;
  Stream<String> get budgetNotifications;
  Future<LedgerReadViewData> readViewData({
    required String month,
    LedgerFilter filter = const LedgerFilter(),
    int recentLimit = 12,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<LedgerTransaction?> transactionById(
    String id, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<WorkspaceMeta> meta();
  Future<WorkspaceMeta> workspaceMeta(String workspace);
  Future<List<WorkspaceMeta>> listWorkspaces();
  Future<void> switchWorkspace(
    String workspace, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<List<Account>> listAccounts({bool includeArchived = true});
  Future<List<Category>> listCategories({EntryType? type});
  Future<List<Budget>> listBudgets({String? month});
  Future<List<BudgetStatus>> budgetStatuses(String month);
  Future<Map<String, int>> balances();
  Future<TransactionPage> search(
    LedgerFilter filter, {
    int offset = 0,
    int limit = 50,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<LedgerSummary> summary({LedgerFilter filter = const LedgerFilter()});
  Future<LedgerStatistics> statistics({
    required String start,
    required String end,
    EntryType type = EntryType.expense,
    bool monthly = false,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> saveTransaction(
    LedgerTransaction entry, {
    bool create = false,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> deleteTransaction(
    String id, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> upsertAccount(
    Account account, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> archiveAccount(
    String id,
    bool archived, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> upsertCategory(
    Category category, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> deleteCategory(
    String id, {
    String? reassignTo,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> upsertBudget(
    Budget budget, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> deleteBudget(
    String month,
    String categoryId, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<LedgerSettings> settings();
  Future<void> updateSettings(
    LedgerSettings settings, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<ImportPreview> previewImport(
    String filePath, {
    int maxTransactions = localTransactionLimit,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<ImportPreview> previewJson(
    String json, {
    int maxTransactions = localTransactionLimit,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> discardImport(ImportPreview preview);
  Future<void> importAtomic(
    ImportPreview preview, {
    String label = '恢复前备份',
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<List<BackupInfo>> listBackups();
  Future<void> restoreBackup(
    BackupInfo backup, {
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> exportFile(
    String path, {
    ExportFormat format = ExportFormat.json,
    LedgerFilter filter = const LedgerFilter(),
    bool cloudCompatible = false,
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<Map<String, Object?>> cloudSnapshot({
    String? expectedWorkspace,
    int? expectedSequence,
  });
  Future<void> replaceSnapshot(
    Map<String, Object?> snapshot, {
    String? workspace,
    int? cloudRevision,
    String? expectedSourceWorkspace,
    int? expectedSequence,
    int? expectedTargetSequence,
    String label = '同步前备份',
  });
  Future<BackupInfo> backupSnapshot(
    Map<String, Object?> snapshot, {
    String label = '云端账本备份',
  });
  Future<void> setCloudRevision(
    int revision, {
    bool dirty = false,
    int? expectedSequence,
    String? workspace,
    String? expectedWorkspace,
  });
  Future<void> writeExport(
    String path,
    ExportFormat format, {
    LedgerFilter filter = const LedgerFilter(),
    String? expectedWorkspace,
    int? expectedSequence,
  }) => exportFile(
    path,
    format: format,
    filter: filter,
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
}
