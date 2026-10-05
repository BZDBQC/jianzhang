package com.jianzhang.qa.faultprovider;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import android.util.Log;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/** QA-only provider: never added to the production application or release APK. */
public final class FaultDocumentsProvider extends DocumentsProvider {
  private static final String[] DOCUMENT_COLUMNS = {
    Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
    Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE
  };
  private static final String[] ROOT_COLUMNS = {
    Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
    Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES, Root.COLUMN_ICON
  };

  @Override public boolean onCreate() { return true; }

  private static void add(MatrixCursor cursor, Map<String, Object> values) {
    MatrixCursor.RowBuilder row = cursor.newRow();
    for (String column : cursor.getColumnNames()) row.add(values.get(column));
  }

  @Override public Cursor queryRoots(String[] projection) {
    MatrixCursor cursor = new MatrixCursor(projection == null ? ROOT_COLUMNS : projection);
    Map<String, Object> row = new HashMap<>();
    row.put(Root.COLUMN_ROOT_ID, "faults");
    row.put(Root.COLUMN_DOCUMENT_ID, "root");
    row.put(Root.COLUMN_TITLE, "简账 QA 故障文件");
    row.put(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY);
    row.put(Root.COLUMN_MIME_TYPES, "application/json");
    row.put(Root.COLUMN_ICON, android.R.drawable.stat_notify_error);
    add(cursor, row);
    return cursor;
  }

  private static void document(MatrixCursor cursor, String id) throws FileNotFoundException {
    Map<String, Object> row = new HashMap<>();
    row.put(Document.COLUMN_DOCUMENT_ID, id);
    row.put(Document.COLUMN_FLAGS, 0);
    row.put(Document.COLUMN_MIME_TYPE, "application/json");
    if ("root".equals(id)) {
      row.put(Document.COLUMN_DISPLAY_NAME, "QA faults");
      row.put(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR);
    } else if ("reliable".equals(id)) row.put(Document.COLUMN_DISPLAY_NAME, "可靠管道错误.json");
    else if ("stalled".equals(id)) row.put(Document.COLUMN_DISPLAY_NAME, "停滞管道.json");
    else if ("corrupt".equals(id)) row.put(Document.COLUMN_DISPLAY_NAME, "损坏 JSON.json");
    else throw new FileNotFoundException("Unknown QA document");
    add(cursor, row);
  }

  @Override public Cursor queryDocument(String id, String[] projection) throws FileNotFoundException {
    MatrixCursor cursor = new MatrixCursor(projection == null ? DOCUMENT_COLUMNS : projection);
    document(cursor, id);
    return cursor;
  }

  @Override public Cursor queryChildDocuments(String parent, String[] projection, String sort)
      throws FileNotFoundException {
    if (!"root".equals(parent)) throw new FileNotFoundException("Unknown QA directory");
    MatrixCursor cursor = new MatrixCursor(projection == null ? DOCUMENT_COLUMNS : projection);
    document(cursor, "reliable"); document(cursor, "stalled"); document(cursor, "corrupt");
    return cursor;
  }

  @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal)
      throws FileNotFoundException {
    if (!"r".equals(mode) || !("reliable".equals(id) || "stalled".equals(id) || "corrupt".equals(id))) {
      throw new FileNotFoundException("QA provider is read-only");
    }
    final ParcelFileDescriptor[] pipe;
    try { pipe = ParcelFileDescriptor.createReliablePipe(); }
    catch (IOException error) { throw new FileNotFoundException("Could not create QA reliable pipe: " + error); }
    Thread worker = new Thread(() -> {
      try (OutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
        Log.i("JianzhangQAFault", "open " + id);
        if ("stalled".equals(id)) {
          // Intentionally ignore CancellationSignal to model a non-cooperating
          // third-party provider. The app must cancel its own reader; this
          // fixture does not prove immediate producer-side release. Its writer
          // is bounded to 30 seconds and is closed on every worker exit.
          Thread.sleep(30000);
          pipe[1].closeWithError("QA_STALLED_PIPE_TIMEOUT");
        } else if ("reliable".equals(id)) {
          // Send a valid legacy ledger before the reliable error. JSON validation
          // alone must not accidentally make this test pass.
          try (InputStream input = getContext().getAssets().open("ledger.json")) {
            byte[] bytes = new byte[4096];
            int count;
            while ((count = input.read(bytes)) != -1) output.write(bytes, 0, count);
          }
          output.flush();
          pipe[1].closeWithError("QA_RELIABLE_PIPE_FAILED");
        } else output.write("{\"transactions\":[}".getBytes(StandardCharsets.UTF_8));
      } catch (InterruptedException error) {
        Thread.currentThread().interrupt();
        Log.i("JianzhangQAFault", "interrupted " + id);
      } catch (IOException error) {
        Log.i("JianzhangQAFault", "closed " + id + ": " + error);
        try { pipe[1].closeWithError("QA_FIXTURE_IO_FAILED"); }
        catch (IOException closeError) { Log.i("JianzhangQAFault", "already closed: " + closeError); }
      } finally {
        try { pipe[1].close(); }
        catch (IOException closeError) { Log.i("JianzhangQAFault", "writer close: " + closeError); }
      }
    }, "qa-document-" + id);
    worker.setDaemon(true);
    worker.start();
    return pipe[0];
  }
}
