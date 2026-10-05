// This helper runs only as part of the actual current-user installer.
// .NET Framework 4.x is included with Windows 10. No runtime download is used.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace JianzhangInstaller {
  public sealed class PayloadFile { public string path; public long bytes; public string sha256; }
  public sealed class Config { public string version; public string qaRoot; public PayloadFile[] files; }
  public sealed class OwnedPayload { public int schemaVersion; public string id; public string version; public List<PayloadFile> files=new List<PayloadFile>(); }
  public sealed class UninstallRecord { public int schemaVersion; public string install; public string phase; public string configBinding; public string ownedJson; public string token; }
  public sealed class RegistryValue { public string key; public string name; public int kind; public string text; public string[] strings; public string binary; public long number; }
  public sealed class Shortcut { public string path; public bool existed; public string backup; public int attributes; public long created; public long modified; public string sha256; }
  public sealed class Journal {
    public string id; public string install; public string registryKey; public string phase;
    public bool hadOld; public bool hadRegistry; public int owner; public long ownerStarted;
    public bool registryTouched; public List<string> shortcutTouched=new List<string>();
    public List<string> createdFolders=new List<string>(); public List<string> registrySubkeys=new List<string>();
    public List<string> createdRegistryParents=new List<string>();
    public List<RegistryValue> registry=new List<RegistryValue>(); public List<Shortcut> shortcuts=new List<Shortcut>();
    public List<PayloadFile> oldFiles=new List<PayloadFile>();
    public List<PayloadFile> preservedFiles=new List<PayloadFile>();
    public List<string> preservedDirectories=new List<string>(); public bool preservationVerified;
    public string oldOwnedSha256; public string oldTokenSha256;
  }
  internal static class Program {
#if INSTALLER_QA
    static readonly bool IsQa=true;
    const string RegistryPath="Software\\Jianzhang\\NativeInstallerQA";
#else
    static readonly bool IsQa=false;
    const string RegistryPath="Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Jianzhang";
#endif
    const string TokenFile=".jianzhang-install-id";
    const string OwnedFile=".jianzhang-payload.json";
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer { MaxJsonLength=16777216 };
    static Config config; static string install; static string marker; static string journalPath;
    static string resultPath; static int owner; static int failNth; static int crashNth; static int step;
    static Journal journal;
    static bool canRollback;
#if INSTALLER_FILE_TESTS
    static Action<string> fileTestFault=null;
#endif
    static void FileBoundary(string name) {
#if INSTALLER_FILE_TESTS
      if(fileTestFault!=null) fileTestFault(name);
#endif
    }

    [STAThread]
    static int Main(string[] args) {
      try {
        if(args.Length!=8) throw new ArgumentException("Installer transaction arguments are incomplete.");
        install=Full(args[1]); config=Json.Deserialize<Config>(File.ReadAllText(args[2],Encoding.UTF8));
        owner=int.Parse(args[3]); failNth=int.Parse(args[4]); crashNth=int.Parse(args[5]); resultPath=args[6];
        // Last argument is the installed manifest identity, supplied by NSIS.
        if(Hash(args[2])!=args[7]) throw new InvalidDataException("Installer manifest identity mismatch.");
        ValidateConfig();
        marker=install+".__jianzhang_transaction"; journalPath=Path.Combine(marker,"journal.json");
        using(var mutex=new Mutex(false,"Local\\JianzhangTransactionHelper"+(IsQa?"QA":"Production"))) {
          bool acquired=false;
          try { try { acquired=mutex.WaitOne(0); } catch(AbandonedMutexException) { acquired=true; }
            if(!acquired) throw new IOException("Another installation transaction is running.");
            switch(args[0]) {
              case "preflight": Preflight(); break;
              case "prepare": Prepare(); break;
              case "commit": Commit(); break;
              case "rollback": ReadJournal(); if(OwnerAlive(journal)&&journal.owner!=owner) throw new IOException("Another installer owns this transaction."); Rollback(); break;
              case "cleanup": ReadJournal(); if(journal.phase!="Committed") throw new IOException("安装仍有未完成恢复，请先重试安装程序。"); CleanupCommitted(); break;
              case "uninstall-preflight": CheckUninstallOwnership(); break;
              case "uninstall-begin": BeginUninstall(); break;
              case "uninstall-delete-payload": DeleteUninstallPayload(); break;
              case "uninstall-finish": FinishUninstall(); break;
              default: throw new ArgumentException("Unknown installer transaction command.");
            }
          } finally { if(acquired) mutex.ReleaseMutex(); }
        }
        WriteResult("OK"); return 0;
      } catch(Exception error) {
        string message=error.Message;
        string personalRecovery=journal==null?null:PersonalRecoveryRoot();
        try {
          if(canRollback && journal!=null && journal.phase!="Committed") { Rollback(); message+="\r\n旧安装状态已恢复。"; }
        } catch(Exception rollbackError) { message+="\r\n恢复失败，保留事务标记和完整备份供下次安装重试："+rollbackError.Message; }
        if(personalRecovery!=null&&Directory.Exists(personalRecovery)) message+="\r\n个人文件恢复副本目录（恢复失败时请重试）："+personalRecovery;
        WriteResult(message); return 2;
      }
    }
    static void WriteResult(string message) {
      if(!String.IsNullOrEmpty(resultPath)) {
        try { File.WriteAllText(resultPath,message,Encoding.Unicode); }
        catch(Exception e) { Console.Error.WriteLine("Cannot write installer result: "+e.Message); }
      }
    }
    static string Full(string path) { return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar); }
    static string Under(string root,string relative) {
      if(String.IsNullOrEmpty(relative)||Path.IsPathRooted(relative)||relative.IndexOf(':')>=0) throw new InvalidDataException("Invalid relative payload path.");
      string path=Path.GetFullPath(Path.Combine(root,relative.Replace('/',Path.DirectorySeparatorChar)));
      if(!path.StartsWith(Full(root)+"\\",StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Payload path escapes its root.");
      return path;
    }
    static void ValidateConfig() {
      if(config==null||config.files==null||config.files.Length==0||String.IsNullOrEmpty(config.version)) throw new InvalidDataException("Invalid installer manifest.");
      if(failNth<0||crashNth<0||failNth>18||crashNth>18||(failNth!=0&&crashNth!=0)) throw new ArgumentException("Invalid QA failure/crash stage.");
      if(install.Length<4||install==Path.GetPathRoot(install).TrimEnd('\\')) throw new IOException("Invalid installation root.");
      if(IsQa) {
        if(String.IsNullOrEmpty(config.qaRoot)||!install.StartsWith(Full(config.qaRoot)+"\\",StringComparison.OrdinalIgnoreCase)) throw new IOException("QA destination must remain inside its fixture root.");
      } else if(failNth!=0||crashNth!=0||!String.IsNullOrEmpty(config.qaRoot)) { throw new InvalidDataException("QA injection is unavailable in production."); }
      foreach(var file in config.files) {
        if(file==null||String.IsNullOrEmpty(file.path)||file.bytes<0||file.sha256==null||file.sha256.Length!=64) throw new InvalidDataException("Payload path is malformed.");
      }
      try {ValidatePathBudget();} catch(PathTooLongException error) {throw new IOException(PathBudgetError().Message,error);}
      foreach(var file in config.files) Under(install,file.path);
      CheckAncestors(install); CheckAncestors(install+".__jianzhang_transaction");
    }
    static void CheckPathBudget(string path,bool directory) {
      // Leave room for NUL (files) and the Win32 directory creation suffix.
      // This helper deliberately does not opt into system long-path settings.
      if(path.Length>=(directory?248:260)) throw PathBudgetError();
      if(!directory) CheckPathBudget(Path.GetDirectoryName(path),true);
    }
    static IOException PathBudgetError() {return new IOException("安装目录或其中的文件路径过长，无法安全创建安装暂存和恢复目录。请选择默认安装目录或更短的路径；此次路径检查未移动或删除现有安装、个人文件和恢复备份。");}
    static string[] ContentBudgetRoots() {
      string id=new string('0',32),transaction=install+".__jianzhang_transaction";
      string recovery=Path.Combine(Path.GetDirectoryName(install),"简账恢复-"+id);
      return new[]{install,Path.Combine(transaction,"stage"),Path.Combine(transaction,"old"),Path.Combine(transaction,"failed-"+id),Path.Combine(recovery,"候选文件-版本2147483647"),Path.Combine(recovery,"旧版文件-版本2147483647")};
    }
    static void CheckRelativePathBudget(string relative,bool directory) {
      foreach(string root in ContentBudgetRoots()) CheckPathBudget(Path.Combine(root,relative.Replace('/',Path.DirectorySeparatorChar)),directory);
    }
    static void ValidatePathBudget() {
      CheckPathBudget(install,true);
      string id=new string('0',32),transaction=install+".__jianzhang_transaction",uninstall=install+".__jianzhang_uninstall";
      string retired=Path.Combine(transaction,"candidate-cleanup-"+id);
      string[] journals={transaction,transaction+".preparing-"+id,transaction+".cleanup-"+id,uninstall,uninstall+".preparing-"+id,uninstall+".cleanup-"+id};
      foreach(string root in ContentBudgetRoots().Concat(journals).Concat(new[]{retired})) CheckPathBudget(root,true);
      foreach(string root in journals) {CheckPathBudget(Path.Combine(root,"journal.json"),false);CheckPathBudget(Path.Combine(root,"journal.json.new"),false);}
      foreach(string name in new[]{OwnedFile,TokenFile}) CheckPathBudget(Path.Combine(retired,name),false);
      foreach(string root in new[]{uninstall,uninstall+".preparing-"+id}) CheckPathBudget(Path.Combine(root,"Uninstall.exe"),false);
      CheckPathBudget(Path.Combine(transaction,"personal-copy","file-"+id),false);
      foreach(string name in new[]{"0.lnk","1.lnk","2.lnk"}) CheckPathBudget(Path.Combine(transaction,"shortcut-backup",name),false);
      CheckPathBudget(Path.Combine(install,".jianzhang-write-"+id+".rename"),false);
      foreach(string relative in config.files.Select(file=>file.path).Concat(new[]{"Uninstall.exe",OwnedFile,TokenFile})) CheckRelativePathBudget(relative,false);
      if(Directory.Exists(install)) {
        // Existing personal files/empty directories must also survive relocation
        // and readable recovery copying; checking only final payload is unsafe.
        foreach(string path in AllFiles(install)) CheckRelativePathBudget(path.Substring(install.Length+1),false);
        foreach(string path in Directory.GetDirectories(install,"*",SearchOption.AllDirectories)) CheckRelativePathBudget(path.Substring(install.Length+1),true);
      }
      // Inspect existing recovery paths before journal parsing or cleanup.
      // Legacy overlong trees remain untouched, including preparing leftovers.
      string parent=Path.GetDirectoryName(install);
      IEnumerable<string> recoveryTrees=new[]{transaction,uninstall};
      if(Directory.Exists(parent)) recoveryTrees=recoveryTrees.Concat(Directory.GetDirectories(parent,Path.GetFileName(transaction)+".*")).Concat(Directory.GetDirectories(parent,Path.GetFileName(uninstall)+".*"));
      foreach(string root in recoveryTrees.Where(Directory.Exists)) {
        CheckPathBudget(root,true);
        foreach(string path in AllFiles(root)) CheckPathBudget(path,false);
        foreach(string path in Directory.GetDirectories(root,"*",SearchOption.AllDirectories)) CheckPathBudget(path,true);
      }
    }
    static void CheckAncestors(string path) {
      string current=path;
      while(!String.IsNullOrEmpty(current)) {
        if(File.Exists(current)) throw new IOException("目录位置被普通文件占用："+current);
        if(Directory.Exists(current)) {
          var attributes=File.GetAttributes(current);
          if((attributes&FileAttributes.ReparsePoint)!=0) throw new IOException("安装目录不能经过链接："+current);
        }
        var parent=Directory.GetParent(current); current=parent==null?null:parent.FullName;
      }
    }
    static void Probe(string directory) {
      string first=Path.Combine(directory,".jianzhang-write-"+Guid.NewGuid().ToString("N"));
      string second=first+".rename";
      try { using(var file=new FileStream(first,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Delete,4096,FileOptions.DeleteOnClose|FileOptions.WriteThrough)) { file.WriteByte(0); file.Flush(true); File.Move(first,second); }
      } finally { if(File.Exists(first)) File.Delete(first); if(File.Exists(second)) File.Delete(second); }
    }
    static string ExistingParent(string path) { while(!Directory.Exists(path)) { var parent=Directory.GetParent(path); if(parent==null) throw new IOException("No writable parent directory."); path=parent.FullName; } return path; }
    static IEnumerable<string> AllFiles(string root) {
      if((File.GetAttributes(root)&FileAttributes.ReparsePoint)!=0) throw new IOException("文件树根目录不能是链接："+root);
      var pending=new Stack<string>(); pending.Push(root);
      while(pending.Count>0) foreach(var path in Directory.GetFileSystemEntries(pending.Pop())) {
        var attributes=File.GetAttributes(path);
        if((attributes&FileAttributes.ReparsePoint)!=0) throw new IOException("安装文件树不能包含链接："+path);
        if((attributes&FileAttributes.Directory)!=0) pending.Push(path); else yield return path;
      }
    }
    static SafeFileHandle LockFile(string file) {
      if((File.GetAttributes(file)&FileAttributes.ReadOnly)!=0) throw new IOException("文件为只读："+file);
      // A checked object must not be writable or replaceable by another opener.
      // Our copy/hash readers share all rights but request only read access.
      var handle=CreateFile(file,0xC0010000,1,IntPtr.Zero,3,0,IntPtr.Zero);
      if(handle.IsInvalid) { int code=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(code,"文件无法写入或替换，可能被占用："+file); }
      return handle;
    }
    static void DeleteLockedFile(SafeFileHandle handle,string path) {
      byte delete=1;
      // FileDispositionInfo binds deletion to the checked object, not a path.
      // No fallback to path deletion: unsupported/locked files remain retryable.
      if(!SetFileInformationByHandle(handle,4,ref delete,1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"无法删除已核验文件，保留文件并重试："+path);
    }
    static string ReadSharedText(string path,Encoding encoding) {
      using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
      using(var reader=new StreamReader(stream,encoding,true)) return reader.ReadToEnd();
    }
    static void CopyIntoLockedFile(SafeFileHandle handle,string source,string target,PayloadFile expected) {
      SafeFileHandle duplicate;
      if(!DuplicateHandle(GetCurrentProcess(),handle,GetCurrentProcess(),out duplicate,0,false,2)) throw new Win32Exception(Marshal.GetLastWin32Error(),"无法复制已核验文件句柄，保留恢复副本。");
      using(duplicate)
      using(var output=new FileStream(duplicate,FileAccess.ReadWrite))
      using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
        output.Position=0; input.CopyTo(output); output.SetLength(output.Position); output.Flush(true);
      }
      if(!MatchesFile(target,expected)) throw new IOException("个人文件合并校验失败，保留双方恢复副本："+expected.path);
    }
    static string[] ShortcutPaths() {
      string menu=IsQa?Path.Combine(install,"_qa","menu"):Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"简账");
      string desktop=IsQa?Path.Combine(install,"_qa","desktop"):Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
      return new[]{Path.Combine(menu,"简账.lnk"),Path.Combine(menu,"卸载简账.lnk"),Path.Combine(desktop,"简账.lnk")};
    }
    static void Preflight() {
      CleanupCompletedUninstall();
      CleanupTerminalDirectories();
      if(Directory.Exists(marker)) {
        ReadJournal();
        if(OwnerAlive(journal)&&journal.owner!=owner) throw new IOException("Another installer owns the pending recovery journal.");
        if(journal.phase=="Committed") CleanupCommitted(); else Rollback();
        journal=null;
      }
      string registered=null;
      using(var key=Registry.CurrentUser.OpenSubKey(RegistryPath,false)) { if(key!=null) registered=key.GetValue("InstallLocation") as string; }
      if(!String.IsNullOrEmpty(registered)&&!String.Equals(Full(registered),install,StringComparison.OrdinalIgnoreCase)&&Directory.Exists(registered)) throw new IOException("已有安装位于 "+registered+"，请在原目录升级。");
      if(Directory.Exists(install)&&Directory.EnumerateFileSystemEntries(install).Any()) {
        if(String.IsNullOrEmpty(registered)||!String.Equals(Full(registered),install,StringComparison.OrdinalIgnoreCase)||!File.Exists(Path.Combine(install,"jianzhang.exe"))||!File.Exists(Path.Combine(install,"Uninstall.exe"))) throw new IOException("非空目录不是已登记的简账安装，请选择独立目录。");
        var preservation=new Journal(); ClassifyPreservedFiles(preservation);
        foreach(var file in AllFiles(install)) using(LockFile(file)) {}
      }
      var parents=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      parents.Add(ExistingParent(Path.GetDirectoryName(install)));
      if(Directory.Exists(install)) parents.Add(install);
      foreach(var file in config.files) {
        string parent=Path.GetDirectoryName(Under(install,file.path)); CheckAncestors(parent);
        if(Directory.Exists(parent)) parents.Add(parent);
      }
      foreach(var shortcut in ShortcutPaths()) {
        CheckAncestors(Path.GetDirectoryName(shortcut)); parents.Add(ExistingParent(Path.GetDirectoryName(shortcut)));
        if(Directory.Exists(shortcut)) throw new IOException("快捷方式位置被目录占用："+shortcut);
        if(File.Exists(shortcut)) using(LockFile(shortcut)) {}
      }
      foreach(var parent in parents) Probe(parent);
      long needed=config.files.Sum(file=>file.bytes)+67108864;
      if(new DriveInfo(Path.GetPathRoot(install)).AvailableFreeSpace<needed) throw new IOException("磁盘空间不足，无法安全暂存完整候选并保留旧版本。");
    }
    static void Prepare() {
      Preflight();
      journal=new Journal {id=Guid.NewGuid().ToString("N"),install=install,registryKey=RegistryPath,phase="Preparing",hadOld=Directory.Exists(install),owner=owner,ownerStarted=Process.GetProcessById(owner).StartTime.ToUniversalTime().Ticks};
      using(var key=Registry.CurrentUser.OpenSubKey(RegistryPath,false)) { journal.hadRegistry=key!=null; if(key!=null) CaptureRegistry(key,"",journal); }
      if(journal.hadOld) foreach(var file in AllFiles(install).OrderBy(path=>path,StringComparer.Ordinal)) journal.oldFiles.Add(new PayloadFile {path=file.Substring(install.Length+1).Replace('\\','/'),bytes=new FileInfo(file).Length,sha256=Hash(file)});
      if(journal.hadOld&&journal.oldFiles.Count>0) ClassifyPreservedFiles(journal);
      string parent=Path.GetDirectoryName(install); var missing=new Stack<string>();
      while(!Directory.Exists(parent)) { missing.Push(parent); parent=Path.GetDirectoryName(parent); }
      while(missing.Count>0) { string next=missing.Pop(); Directory.CreateDirectory(next); journal.createdFolders.Add(next); }
      PublishInitialJournal(); canRollback=true;
      Directory.CreateDirectory(Path.Combine(marker,"shortcut-backup"));
      var shortcuts=ShortcutPaths();
      for(int i=0;i<shortcuts.Length;i++) {
        string path=shortcuts[i]; bool exists=File.Exists(path);
        var snapshot=new Shortcut {path=path,existed=exists,backup="shortcut-backup/"+i+".lnk"};
        if(exists) { snapshot.attributes=(int)File.GetAttributes(path); snapshot.created=File.GetCreationTimeUtc(path).Ticks; snapshot.modified=File.GetLastWriteTimeUtc(path).Ticks; snapshot.sha256=Hash(path); File.Copy(path,Under(marker,snapshot.backup)); }
        journal.shortcuts.Add(snapshot);
      }
      Directory.CreateDirectory(Path.Combine(marker,"stage"));
      journal.phase="Prepared"; Save();
    }
    static void CaptureRegistry(RegistryKey key,string relative,Journal snapshot) {
      snapshot.registrySubkeys.Add(relative);
      foreach(string name in key.GetValueNames().OrderBy(value=>value,StringComparer.Ordinal)) {
        var kind=key.GetValueKind(name); object data=key.GetValue(name,null,RegistryValueOptions.DoNotExpandEnvironmentNames);
        var value=new RegistryValue {key=relative,name=name,kind=(int)kind};
        if(data is byte[]) value.binary=Convert.ToBase64String((byte[])data);
        else if(data is string[]) value.strings=(string[])data;
        else if(data is string) value.text=(string)data;
        else value.number=Convert.ToInt64(data);
        snapshot.registry.Add(value);
      }
      foreach(string child in key.GetSubKeyNames().OrderBy(value=>value,StringComparer.Ordinal)) using(var nested=key.OpenSubKey(child,false)) { CaptureRegistry(nested,String.IsNullOrEmpty(relative)?child:relative+"\\"+child,snapshot); }
    }
    static void Save() {
      WriteJournal(journalPath,journal);
    }
    static void WriteJournal(string path,Journal state) {
      string temporary=path+".new";
      byte[] bytes=Encoding.UTF8.GetBytes(Json.Serialize(state));
      FileBoundary("journal.beforeCreate");
      using(var stream=new FileStream(temporary,FileMode.Create,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) {
        FileBoundary("journal.beforeWrite"); stream.Write(bytes,0,bytes.Length);
        FileBoundary("journal.beforeFlush"); stream.Flush(true); FileBoundary("journal.afterFlush");
      }
      if(File.Exists(path)) File.Replace(temporary,path,null); else File.Move(temporary,path);
    }
    static void PublishInitialJournal() {
      // This unpublished sibling can contain only the initial journal. A crash
      // here cannot leave a visible marker without a complete recovery record.
      string preparing=marker+".preparing-"+journal.id;
      CheckAncestors(preparing);
      if(Directory.Exists(preparing)) throw new IOException("Initial transaction directory already exists.");
      Directory.CreateDirectory(preparing);
      try {
        WriteJournal(Path.Combine(preparing,"journal.json"),journal);
        FileBoundary("publish.beforeMove"); Directory.Move(preparing,marker);
      } catch(Exception error) {
        try { AllFiles(preparing).ToArray(); Directory.Delete(preparing,true); }
        catch(Exception cleanupError) { throw new IOException("未发布的临时日志保留在 "+preparing+"，不会阻断下次安装："+cleanupError.Message,error); }
        throw;
      }
    }
    static void ReadJournal() {
      if(!File.Exists(journalPath)) throw new IOException("事务目录缺少恢复日志，保留文件并停止安装："+marker);
      journal=LoadJournal(journalPath);
    }
    static Journal LoadJournal(string path) {
      var state=Json.Deserialize<Journal>(ReadSharedText(path,Encoding.UTF8));
      Guid id;
      if(state==null||state.install!=install||state.registryKey!=RegistryPath||String.IsNullOrEmpty(state.id)||state.id.Length!=32||!Guid.TryParseExact(state.id,"N",out id)) throw new InvalidDataException("恢复日志与目标安装不一致。");
      foreach(var shortcut in state.shortcuts) if(!ShortcutPaths().Contains(shortcut.path,StringComparer.OrdinalIgnoreCase)) throw new InvalidDataException("恢复日志包含外部快捷方式。");
      foreach(string folder in state.createdFolders) if(!install.StartsWith(Full(folder)+"\\",StringComparison.OrdinalIgnoreCase)&&!ShortcutPaths().Any(shortcut=>shortcut.StartsWith(Full(folder)+"\\",StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException("恢复日志包含外部目录。");
      return state;
    }
    static bool OwnerAlive(Journal state) {
      try { return Process.GetProcessById(state.owner).StartTime.ToUniversalTime().Ticks==state.ownerStarted; }
      catch(ArgumentException) { return false; }
      catch(InvalidOperationException) { return false; }
    }
    static void CheckFiles(string root,IEnumerable<PayloadFile> expected,bool exact) {
      var files=expected.ToArray();
      if(exact&&AllFiles(root).Count()!=files.Length) throw new InvalidDataException("文件清单数量改变："+root);
      foreach(var file in files) { string path=Under(root,file.path); if(!File.Exists(path)||new FileInfo(path).Length!=file.bytes||Hash(path)!=file.sha256) throw new InvalidDataException("文件清单校验失败："+file.path); }
    }
    static bool TokenMatches(string root,string id) {
      string path=Path.Combine(root,TokenFile);
      return File.Exists(path)&&ReadSharedText(path,Encoding.ASCII).Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()==id;
    }
    static OwnedPayload ReadOwnedPayload(string root) {
      string path=Path.Combine(root,OwnedFile),token=Path.Combine(root,TokenFile);
      if(!File.Exists(path)||!File.Exists(token)) throw new IOException("旧安装缺少可信程序文件清单，未移动或删除旧目录。请先导出账本并完整备份原安装及恢复目录，用原版本卸载器移除旧登记，再选择空目录安装新版。");
      CheckAncestors(root); AllFiles(root).ToArray();
      string[] identity=ReadSharedText(token,Encoding.ASCII).Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries);
      var owned=Json.Deserialize<OwnedPayload>(ReadSharedText(path,Encoding.UTF8)); Guid id;
      if(identity.Length!=2||owned==null||owned.schemaVersion!=1||owned.files==null||owned.files.Count==0||String.IsNullOrEmpty(owned.version)||!Guid.TryParseExact(owned.id,"N",out id)||identity[0]!=owned.id||identity[1]!=Hash(path)) throw new InvalidDataException("程序文件清单身份不完整或已改变，保留全部文件并停止。");
      var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach(var file in owned.files) {
        string canonical=Under(root,file.path).Substring(Full(root).Length+1).Replace('\\','/');
        if(canonical!=file.path||file.path==TokenFile||file.path==OwnedFile||!paths.Add(canonical)||file.bytes<0||file.sha256==null||file.sha256.Length!=64||!file.sha256.All(Uri.IsHexDigit)) throw new InvalidDataException("程序文件清单包含无效路径或校验值。");
      }
      if(!paths.Contains("jianzhang.exe")||!paths.Contains("Uninstall.exe")) throw new InvalidDataException("程序文件清单缺少安装入口。");
      return owned;
    }
    static void WriteOwnedPayload(string stage) {
      var owned=new OwnedPayload {schemaVersion=1,id=journal.id,version=config.version};
      owned.files.AddRange(config.files);
      string uninstaller=Path.Combine(stage,"Uninstall.exe");
      owned.files.Add(new PayloadFile {path="Uninstall.exe",bytes=new FileInfo(uninstaller).Length,sha256=Hash(uninstaller)});
      string path=Path.Combine(stage,OwnedFile);
      byte[] data=Encoding.UTF8.GetBytes(Json.Serialize(owned));
      using(var file=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) { file.Write(data,0,data.Length); file.Flush(true); }
      string token=Path.Combine(stage,TokenFile);
      File.WriteAllText(token,journal.id+"\n"+Hash(path)+"\n",Encoding.ASCII);
      File.SetAttributes(path,FileAttributes.Hidden); File.SetAttributes(token,FileAttributes.Hidden);
    }
    static void ClassifyPreservedFiles(Journal state) {
      var owned=ReadOwnedPayload(install);
      state.oldOwnedSha256=Hash(Path.Combine(install,OwnedFile)); state.oldTokenSha256=Hash(Path.Combine(install,TokenFile));
      var known=owned.files.ToDictionary(file=>file.path,StringComparer.OrdinalIgnoreCase);
      var ownedDirectories=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach(var file in owned.files) {
        string parent=Path.GetDirectoryName(file.path.Replace('/',Path.DirectorySeparatorChar));
        while(!String.IsNullOrEmpty(parent)) { ownedDirectories.Add(parent.Replace('\\','/')); parent=Path.GetDirectoryName(parent); }
      }
      state.preservedFiles.Clear(); state.preservedDirectories.Clear();
      foreach(string path in AllFiles(install)) {
        string relative=path.Substring(install.Length+1).Replace('\\','/');
        if(relative==TokenFile||relative==OwnedFile||(IsQa&&ShortcutPaths().Contains(path,StringComparer.OrdinalIgnoreCase))) continue;
        PayloadFile file;
        if(known.TryGetValue(relative,out file)&&new FileInfo(path).Length==file.bytes&&Hash(path)==file.sha256) continue;
        state.preservedFiles.Add(new PayloadFile {path=relative,bytes=new FileInfo(path).Length,sha256=Hash(path)});
      }
      foreach(string path in Directory.GetDirectories(install,"*",SearchOption.AllDirectories)) {
        string relative=path.Substring(install.Length+1).Replace('\\','/');
        if(!ownedDirectories.Contains(relative)) state.preservedDirectories.Add(relative);
      }
      CheckPreservationCollisions(state);
    }
    static void CheckPreservationCollisions(Journal state) {
      var payload=config.files.Select(file=>file.path).Concat(new[]{"Uninstall.exe",TokenFile,OwnedFile}).ToArray();
      foreach(var extra in state.preservedFiles) foreach(string path in payload) {
        if(String.Equals(extra.path,path,StringComparison.OrdinalIgnoreCase)||extra.path.StartsWith(path+"/",StringComparison.OrdinalIgnoreCase)||path.StartsWith(extra.path+"/",StringComparison.OrdinalIgnoreCase)) throw new IOException("个人文件与新版程序路径冲突，未覆盖旧文件："+extra.path);
      }
      foreach(string directory in state.preservedDirectories) foreach(string path in payload) if(String.Equals(directory,path,StringComparison.OrdinalIgnoreCase)||directory.StartsWith(path+"/",StringComparison.OrdinalIgnoreCase)) throw new IOException("个人目录与新版程序路径冲突，未覆盖旧目录："+directory);
    }
    static void CopyPreservedFiles(string stage) {
      CheckPreservationCollisions(journal);
      foreach(string relative in journal.preservedDirectories) Directory.CreateDirectory(Under(stage,relative));
      foreach(var file in journal.preservedFiles) {
        string source=Under(install,file.path),target=Under(stage,file.path); Directory.CreateDirectory(Path.GetDirectoryName(target));
        FileBoundary("preserve.beforeCopy");
        using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) { input.CopyTo(output); output.Flush(true); }
        File.SetCreationTimeUtc(target,File.GetCreationTimeUtc(source)); File.SetLastWriteTimeUtc(target,File.GetLastWriteTimeUtc(source)); File.SetAttributes(target,File.GetAttributes(source));
      }
      CheckFiles(stage,journal.preservedFiles,false);
      journal.preservationVerified=true; Save();
    }
    static void CheckUninstallOwnership() {
      var record=Directory.Exists(UninstallRoot())?ReadUninstallRecord():null;
      var owned=record==null?ReadOwnedPayload(install):OwnedFromRecord(record);
      if(record!=null) {
        if(record.configBinding!=ConfigBinding()) throw new IOException("卸载恢复记录与卸载器不匹配，保留所有文件。");
        foreach(string name in new[]{OwnedFile,TokenFile}) {
          string path=Path.Combine(install,name);
          if(Directory.Exists(path)) throw new IOException("卸载身份位置被个人目录占用，停止卸载。");
          if(File.Exists(path)&&Hash(path)!=HashText(name==OwnedFile?record.ownedJson:record.token)) throw new IOException("卸载身份文件已改变，保留并停止。");
        }
      }
      var expected=config.files.ToDictionary(file=>file.path,StringComparer.OrdinalIgnoreCase);
      if(owned.version!=config.version||owned.files.Count!=config.files.Length+1) throw new IOException("卸载器与程序文件清单版本不匹配，保留所有文件。");
      foreach(var file in owned.files) {
        PayloadFile match;
        if(file.path!="Uninstall.exe"&&(!expected.TryGetValue(file.path,out match)||match.sha256!=file.sha256||match.bytes!=file.bytes)) throw new IOException("卸载器文件清单不匹配，保留所有文件。");
        string path=Under(install,file.path);
        if(!File.Exists(path)&&!Directory.Exists(path)&&record==null) throw new IOException("程序文件已缺失但未开始可信卸载，保留文件并停止："+file.path);
        if(File.Exists(path)&&(new FileInfo(path).Length!=file.bytes||Hash(path)!=file.sha256)) throw new IOException("程序路径含已修改文件，保留该文件并停止卸载："+file.path);
        if(Directory.Exists(path)) throw new IOException("程序文件位置含个人目录，保留目录并停止卸载："+file.path);
      }
    }
    static string UninstallRoot() { return install+".__jianzhang_uninstall"; }
    static string HashText(string text) { using(var hash=SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-","").ToLowerInvariant(); }
    static string ConfigBinding() { return HashText(config.version+"\n"+Json.Serialize(config.files)); }
    static OwnedPayload OwnedFromRecord(UninstallRecord record) {
      var owned=Json.Deserialize<OwnedPayload>(record.ownedJson); string[] token=record.token.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries); Guid id;
      if(owned==null||owned.schemaVersion!=1||owned.files==null||owned.files.Count==0||String.IsNullOrEmpty(owned.version)||!Guid.TryParseExact(owned.id,"N",out id)||token.Length!=2||token[0]!=owned.id||token[1]!=HashText(record.ownedJson)) throw new InvalidDataException("卸载恢复身份不完整。");
      var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach(var file in owned.files) if(Under(install,file.path).Substring(install.Length+1).Replace('\\','/')!=file.path||file.path==OwnedFile||file.path==TokenFile||!names.Add(file.path)||file.bytes<0||file.sha256==null||file.sha256.Length!=64||!file.sha256.All(Uri.IsHexDigit)) throw new InvalidDataException("卸载恢复清单无效。");
      if(!names.Contains("jianzhang.exe")||!names.Contains("Uninstall.exe")) throw new InvalidDataException("卸载恢复清单缺少入口。");
      return owned;
    }
    static UninstallRecord ReadUninstallRecord() {
      string root=UninstallRoot(); CheckAncestors(root); AllFiles(root).ToArray();
      string path=Path.Combine(root,"journal.json");
      if(!File.Exists(path)) throw new IOException("卸载恢复日志缺失，保留文件并停止。");
      var record=Json.Deserialize<UninstallRecord>(File.ReadAllText(path,Encoding.UTF8));
      if(record==null||record.schemaVersion!=1||record.install!=install||(record.phase!="Uninstalling"&&record.phase!="Completed")||record.configBinding==null||record.configBinding.Length!=64) throw new InvalidDataException("卸载恢复日志身份无效。");
      var owned=OwnedFromRecord(record); var entry=owned.files.Single(file=>file.path=="Uninstall.exe");
      string backup=Path.Combine(root,"Uninstall.exe");
      if(File.Exists(backup)&&(new FileInfo(backup).Length!=entry.bytes||Hash(backup)!=entry.sha256)) throw new IOException("卸载器恢复副本发生变化，保留并停止。");
      if(!File.Exists(backup)&&record.phase!="Completed") throw new IOException("卸载器恢复副本缺失。");
      return record;
    }
    static void SaveUninstallRecord(string path,UninstallRecord record) {
      string temporary=path+".new"; byte[] bytes=Encoding.UTF8.GetBytes(Json.Serialize(record));
      using(var file=new FileStream(temporary,FileMode.Create,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) { file.Write(bytes,0,bytes.Length); file.Flush(true); }
      if(File.Exists(path)) File.Replace(temporary,path,null); else File.Move(temporary,path);
    }
    static void BeginUninstall() {
      CheckUninstallOwnership(); if(Directory.Exists(UninstallRoot())) return;
      var record=new UninstallRecord {schemaVersion=1,install=install,phase="Uninstalling",configBinding=ConfigBinding(),ownedJson=File.ReadAllText(Path.Combine(install,OwnedFile),Encoding.UTF8),token=File.ReadAllText(Path.Combine(install,TokenFile),Encoding.ASCII)};
      var owned=OwnedFromRecord(record); string temporary=UninstallRoot()+".preparing-"+Guid.NewGuid().ToString("N"); CheckAncestors(temporary);
      if(Directory.Exists(temporary)) throw new IOException("卸载日志暂存目录已存在，未删除程序文件。");
      Directory.CreateDirectory(temporary);
      try {
        using(var input=new FileStream(Path.Combine(install,"Uninstall.exe"),FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var output=new FileStream(Path.Combine(temporary,"Uninstall.exe"),FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) { input.CopyTo(output); output.Flush(true); }
        var entry=owned.files.Single(file=>file.path=="Uninstall.exe"); CheckFiles(temporary,new[]{entry},false);
        SaveUninstallRecord(Path.Combine(temporary,"journal.json"),record);
        FileBoundary("uninstall.beforePublish"); Directory.Move(temporary,UninstallRoot());
      } catch { AllFiles(temporary).ToArray(); Directory.Delete(temporary,true); throw; }
    }
    static void FinishUninstall() {
      CheckUninstallOwnership(); var record=ReadUninstallRecord(); var owned=OwnedFromRecord(record);
      if(owned.files.Any(file=>file.path!="Uninstall.exe"&&(File.Exists(Under(install,file.path))||Directory.Exists(Under(install,file.path))))) throw new IOException("程序文件尚未全部移除，卸载入口和身份保留供重试。");
      foreach(string name in new[]{OwnedFile,TokenFile}) {
        string path=Path.Combine(install,name);
        bool deleted=false;
        if(File.Exists(path)) using(var locked=LockFile(path)) {
          if(Hash(path)!=HashText(name==OwnedFile?record.ownedJson:record.token)) throw new IOException("卸载身份文件已改变，停止删除。");
          FileBoundary("uninstall.beforeDelete."+name); DeleteLockedFile(locked,path); deleted=true;
        }
        if(deleted) FileBoundary("uninstall.afterDelete."+name);
      }
      // Publish completion before the final entry deletion. No later cleanup
      // can turn a completed uninstall into an unretryable failure. This small
      // journal/backup is cleaned by the next actual installer preflight.
      if(record.phase!="Completed") {record.phase="Completed"; SaveUninstallRecord(Path.Combine(UninstallRoot(),"journal.json"),record);}
      string uninstaller=Path.Combine(install,"Uninstall.exe");
      if(File.Exists(uninstaller)) using(var locked=LockFile(uninstaller)) {
        var entry=owned.files.Single(file=>file.path=="Uninstall.exe");
        if(new FileInfo(uninstaller).Length!=entry.bytes||Hash(uninstaller)!=entry.sha256) throw new IOException("卸载入口已改变，保留并停止。");
        FileBoundary("uninstall.beforeDeleteEntry"); DeleteLockedFile(locked,uninstaller);
      }
    }
    static void DeleteUninstallPayload() {
      CheckUninstallOwnership(); var owned=OwnedFromRecord(ReadUninstallRecord());
      foreach(var file in owned.files.Where(file=>file.path!="Uninstall.exe")) {
        string path=Under(install,file.path); CheckAncestors(Path.GetDirectoryName(path));
        if(Directory.Exists(path)) throw new IOException("程序文件位置含个人目录，停止删除："+file.path);
        if(!File.Exists(path)) continue;
        using(var locked=LockFile(path)) {
          if(new FileInfo(path).Length!=file.bytes||Hash(path)!=file.sha256) throw new IOException("程序文件已被改写，保留并停止删除："+file.path);
          FileBoundary("uninstall.beforeDeletePayload"); DeleteLockedFile(locked,path);
        }
      }
    }
    static void CleanupCompletedUninstall() {
      if(!Directory.Exists(UninstallRoot())) return;
      var record=ReadUninstallRecord();
      if(record.phase!="Completed"||File.Exists(Path.Combine(install,"Uninstall.exe"))) throw new IOException("上次卸载未完成，请先重试原卸载器；个人文件和账本保持保留。");
      string root=UninstallRoot();
      if(Directory.GetDirectories(root).Length!=0||Directory.GetFiles(root).Any(path=>Path.GetFileName(path)!="journal.json"&&Path.GetFileName(path)!="journal.json.new"&&Path.GetFileName(path)!="Uninstall.exe")) throw new IOException("卸载恢复目录含未知文件，保留并停止。");
      foreach(string name in new[]{"Uninstall.exe","journal.json.new"}) {
        string path=Path.Combine(root,name);
        if(File.Exists(path)) using(var locked=LockFile(path)) {
          if(name=="Uninstall.exe") {var entry=OwnedFromRecord(record).files.Single(file=>file.path==name);if(!MatchesFile(path,entry)) throw new IOException("卸载入口恢复副本已改变，保留并停止清理。");}
          else {var pending=Json.Deserialize<UninstallRecord>(ReadSharedText(path,Encoding.UTF8));if(pending==null||pending.install!=record.install||pending.configBinding!=record.configBinding||pending.ownedJson!=record.ownedJson||pending.token!=record.token) throw new IOException("卸载日志暂存文件身份改变，保留并停止清理。");}
          FileBoundary("uninstall.beforeCleanupDelete."+name); DeleteLockedFile(locked,path);
        }
      }
      string terminal=root+".cleanup-"+OwnedFromRecord(record).id; Directory.Move(root,terminal);
      // Only a terminal journal remains after the atomic retirement. An
      // interrupted removal cannot block the next installation's active marker.
      string finalJournal=Path.Combine(terminal,"journal.json");
      using(var locked=LockFile(finalJournal)) {
        var completed=Json.Deserialize<UninstallRecord>(ReadSharedText(finalJournal,Encoding.UTF8));
        if(completed==null||completed.phase!="Completed"||completed.install!=record.install||completed.configBinding!=record.configBinding||completed.ownedJson!=record.ownedJson||completed.token!=record.token) throw new IOException("卸载清理日志身份改变，保留并停止。");
        FileBoundary("uninstall.beforeCleanupDelete.journal.json"); DeleteLockedFile(locked,finalJournal);
      }
      Directory.Delete(terminal,false);
    }
    static void Step(string name) {
      step++;
#if INSTALLER_QA
      File.AppendAllText(Path.Combine(config.qaRoot,"steps.log"),step+":"+name+"\r\n",Encoding.UTF8);
      if(step==crashNth) Environment.Exit(99);
      if(step==failNth) throw new IOException("QA failure injected at step "+step+": "+name);
#endif
    }
    static void Commit() {
      ReadJournal();
      if(journal.owner!=owner||!OwnerAlive(journal)||journal.phase!="Prepared") throw new IOException("Installation transaction is not owned by this installer.");
      canRollback=true;
      if(IsQa&&(failNth>17+(journal.hadOld?1:0)||crashNth>17+(journal.hadOld?1:0))) throw new ArgumentException("QA stage does not exist for this installation mode.");
      var locks=new List<SafeFileHandle>();
      try {
        CommitPayload(locks);
        for(int i=0;i<journal.shortcuts.Count;i++) {
          var shortcut=journal.shortcuts[i]; string directory=Path.GetDirectoryName(shortcut.path);
          Step("shortcut.directory."+i);
          CreateTrackedDirectory(directory);
          journal.shortcutTouched.Add(shortcut.path); Save(); Step("shortcut.write."+i);
          CreateShortcut(shortcut.path,Path.Combine(install,i==1?"Uninstall.exe":"jianzhang.exe"));
        }
        string parent=RegistryPath;
        while(parent.LastIndexOf('\\')>0) {
          parent=parent.Substring(0,parent.LastIndexOf('\\'));
          using(var existing=Registry.CurrentUser.OpenSubKey(parent,false)) { if(existing==null) journal.createdRegistryParents.Add(parent); }
        }
        journal.registryTouched=true; Save(); Step("registration.create");
        using(var key=Registry.CurrentUser.CreateSubKey(RegistryPath)) {
          WriteValue(key,"DisplayName","简账"); WriteValue(key,"DisplayVersion",config.version); WriteValue(key,"Publisher","简账");
          WriteValue(key,"InstallLocation",install); WriteValue(key,"DisplayIcon",Path.Combine(install,"jianzhang.exe"));
          WriteValue(key,"UninstallString","\""+Path.Combine(install,"Uninstall.exe")+"\""); WriteValue(key,"NoModify",1); WriteValue(key,"NoRepair",1);
          key.Flush();
        }
        Step("journal.commit"); journal.phase="Committed"; Save();
      } finally { foreach(var handle in locks) handle.Dispose(); }
      // The complete old payload remains in the committed recovery directory.
      // The next actual installer removes it before preparing another candidate.
      // A post-commit cleanup failure must not turn a coherent install into a
      // failed transaction after its rollback copy has been partly deleted.
    }
    // File-only portion shared with the isolated regression harness. The caller
    // keeps these locks until registration/shortcuts commit or recovery begins.
    static void CommitPayload(List<SafeFileHandle> locks) {
      string stage=Path.Combine(marker,"stage");
      CheckFiles(stage,config.files,false);
      if(!File.Exists(Path.Combine(stage,"Uninstall.exe"))) throw new IOException("Missing staged uninstaller.");
      if(AllFiles(stage).Count()!=config.files.Length+1) throw new InvalidDataException("Unexpected staged file.");
        if(journal.hadOld) {
          foreach(var file in AllFiles(install)) locks.Add(LockFile(file));
          CheckFiles(install,journal.oldFiles,true);
          CopyPreservedFiles(stage);
        } else { journal.preservationVerified=true; Save(); }
        WriteOwnedPayload(stage);
        if(AllFiles(stage).Count()!=config.files.Length+3+journal.preservedFiles.Count) throw new InvalidDataException("Unexpected staged file after preserving user files.");
        if(journal.hadOld) {
          journal.phase="MovingOld"; Save(); Step("payload.backup");
          // Windows refuses a directory rename while its child file handles are
          // open. Strict locks are released only for this atomic directory move;
          // reacquire and verify the entire backup immediately afterward.
          foreach(var handle in locks) handle.Dispose(); locks.Clear();
          FileBoundary("payload.afterUnlock");
          string old=Path.Combine(marker,"old"); Directory.Move(install,old);
          FileBoundary("payload.beforeRelock");
          foreach(string file in AllFiles(old)) locks.Add(LockFile(file));
          CheckFiles(old,journal.oldFiles,true);
          journal.phase="OldMoved"; Save();
        }
        journal.phase="InstallingNew"; Save(); Step("payload.commit"); Directory.Move(stage,install);
        journal.phase="PayloadInstalled"; Save();
    }
    static void WriteValue(RegistryKey key,string name,object value) { Step("registration."+name); key.SetValue(name,value,value is int?RegistryValueKind.DWord:RegistryValueKind.String); }
    static void CreateTrackedDirectory(string directory) {
      var missing=new Stack<string>(); string current=directory;
      while(!Directory.Exists(current)) { missing.Push(current); current=Path.GetDirectoryName(current); }
      while(missing.Count>0) { string next=missing.Pop(); journal.createdFolders.Add(next); Save(); Directory.CreateDirectory(next); }
    }
    static void Rollback() {
      if(journal==null) return;
      if(journal.phase=="Committed") throw new IOException("A committed transaction must not be rolled back.");
      if(journal.phase=="RolledBack") { if(Directory.Exists(marker)) Save(); FinishRollbackCleanup(); return; }
      RestorePayload();
      if(journal.registryTouched) {
        if(!RegistryMatchesSnapshot()) RestoreRegistry();
        foreach(string parent in journal.createdRegistryParents.OrderByDescending(value=>value.Length)) {
          if(!RegistryPath.StartsWith(parent+"\\",StringComparison.Ordinal)) throw new InvalidDataException("恢复日志包含外部注册目录。");
          bool empty=false;
          using(var key=Registry.CurrentUser.OpenSubKey(parent,false)) { empty=key!=null&&key.GetValueNames().Length==0&&key.GetSubKeyNames().Length==0; }
          if(empty) Registry.CurrentUser.DeleteSubKey(parent,false);
        }
      }
      foreach(var snapshot in journal.shortcuts.Where(value=>journal.shortcutTouched.Contains(value.path))) {
        if(snapshot.existed) {
          string backup=Under(marker,snapshot.backup);
          if(Hash(backup)!=snapshot.sha256) throw new InvalidDataException("Shortcut backup checksum mismatch.");
          Directory.CreateDirectory(Path.GetDirectoryName(snapshot.path)); File.Copy(backup,snapshot.path,true);
          File.SetCreationTimeUtc(snapshot.path,new DateTime(snapshot.created,DateTimeKind.Utc)); File.SetLastWriteTimeUtc(snapshot.path,new DateTime(snapshot.modified,DateTimeKind.Utc)); File.SetAttributes(snapshot.path,(FileAttributes)snapshot.attributes);
        } else if(File.Exists(snapshot.path)) File.Delete(snapshot.path);
      }
      journal.phase="RolledBack"; Save();
      FinishRollbackCleanup();
    }
    static void FinishRollbackCleanup() {
      DeleteOwnedTree(marker);
      foreach(string directory in journal.createdFolders.OrderByDescending(path=>path.Length)) if(Directory.Exists(directory)&&!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
      journal=null;
    }
    static void ValidateOldRecoveryIdentity(string root) {
      CheckAncestors(root); AllFiles(root).ToArray();
      if(!String.IsNullOrEmpty(journal.oldOwnedSha256)&&!String.IsNullOrEmpty(journal.oldTokenSha256)) {
        if(!File.Exists(Path.Combine(root,OwnedFile))||!File.Exists(Path.Combine(root,TokenFile))||Hash(Path.Combine(root,OwnedFile))!=journal.oldOwnedSha256||Hash(Path.Combine(root,TokenFile))!=journal.oldTokenSha256) throw new IOException("旧安装恢复身份改变，保留目录并停止。");
        ReadOwnedPayload(root);
      } else if(journal.oldFiles.Count!=0) {
        // Compatibility journals may predate the explicit identity fields.
        // Use their recorded metadata hashes, never a personal-content hash.
        var metadata=journal.oldFiles.Where(file=>file.path==OwnedFile||file.path==TokenFile).ToArray();
        if(metadata.Length!=2) throw new IOException("历史恢复日志缺少可信旧安装身份，保留目录供手动备份。");
        CheckFiles(root,metadata,false); ReadOwnedPayload(root);
      }
    }
    static void RestorePayload() {
      string old=Path.Combine(marker,"old");
      if(Directory.Exists(old)) {
        ValidateOldRecoveryIdentity(old);
        // Preserve edits/additions/deletions in the trusted old directory. The
        // staging copy is a snapshot and must never replace newer personal data.
        MoveNewAside(); PreserveFailedCandidates(old,false); Directory.Move(old,install); FileBoundary("rollback.afterRestoreOld");
      } else if(!journal.hadOld) MoveNewAside();
      else if(!Directory.Exists(install)) throw new IOException("旧程序目录及其备份均不存在。");
      else { ValidateOldRecoveryIdentity(install); PreserveFailedCandidates(install,false); }
    }
    static void MoveNewAside() {
      if(!Directory.Exists(install)) return;
      // New personal paths can appear after initial preflight; reject an unsafe
      // relocation before moving a candidate into an unusable recovery tree.
      try {ValidatePathBudget();} catch(PathTooLongException error) {throw new IOException(PathBudgetError().Message,error);}
      if(!TokenMatches(install,journal.id)) {
        if(journal.hadOld&&!Directory.Exists(Path.Combine(marker,"old"))) return;
        if(journal.phase=="Preparing"||journal.phase=="Prepared"||journal.phase=="InstallingNew") return;
        throw new IOException("当前程序目录不属于本次候选，保留备份并停止恢复。");
      }
      string failed=Path.Combine(marker,"failed-"+journal.id);
      if(Directory.Exists(failed)) throw new IOException("候选恢复目录已存在，保留两侧目录并停止。");
      Directory.Move(install,failed); FileBoundary("rollback.afterMoveCandidate");
    }
    static string PersonalRecoveryRoot() { return Path.Combine(Path.GetDirectoryName(install),"简账恢复-"+journal.id); }
    static PayloadFile FileSnapshot(string root,string path) { return new PayloadFile {path=path.Substring(root.Length+1).Replace('\\','/'),bytes=new FileInfo(path).Length,sha256=Hash(path)}; }
    static bool MatchesFile(string path,PayloadFile file) { return File.Exists(path)&&new FileInfo(path).Length==file.bytes&&Hash(path)==file.sha256; }
    static void CopyVerified(string source,string target,PayloadFile file) {
      CheckAncestors(Path.GetDirectoryName(target)); Directory.CreateDirectory(Path.GetDirectoryName(target));
      using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
      using(var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) { input.CopyTo(output); output.Flush(true); }
      if(!MatchesFile(target,file)) throw new IOException("个人文件恢复副本校验失败："+file.path);
      File.SetLastWriteTimeUtc(target,File.GetLastWriteTimeUtc(source));
    }
    static string SavePersonalCopy(string source,PayloadFile file,string side) {
      string root=Path.Combine(PersonalRecoveryRoot(),side);
      // Never overwrite a previous recovery version or an unrelated file. The
      // same bytes reuse an existing verified copy on interrupted retries.
      for(int version=0;;version++) {
        string target=Under(version==0?root:root+"-版本"+version,file.path);
        CheckAncestors(Path.GetDirectoryName(target));
        if(MatchesFile(target,file)) return target;
        if(File.Exists(target)||Directory.Exists(target)) {if(version==Int32.MaxValue) throw new IOException("个人文件恢复版本过多，保留当前候选文件并停止。");continue;}
        string temporary=Path.Combine(marker,"personal-copy","file-"+Guid.NewGuid().ToString("N"));
        try { CopyVerified(source,temporary,file); CheckAncestors(Path.GetDirectoryName(target)); Directory.CreateDirectory(Path.GetDirectoryName(target)); File.Move(temporary,target); }
        catch { if(File.Exists(temporary)) File.Delete(temporary); throw; }
        FileBoundary("rollback.afterPersonalCopy"); return target;
      }
    }
    static bool HasFileAncestor(string path,string root) {
      string parent=Path.GetDirectoryName(path);
      while(parent.StartsWith(Full(root)+"\\",StringComparison.OrdinalIgnoreCase)) { if(File.Exists(parent)) return true; parent=Path.GetDirectoryName(parent); }
      return false;
    }
    static void RestorePersonalFile(string source,PayloadFile file,string oldRoot,IDictionary<string,PayloadFile> oldOwned,IDictionary<string,PayloadFile> baseline) {
      SavePersonalCopy(source,file,"候选文件");
      if(oldRoot==null) return; // A failed first install still keeps user bytes.
      string target=Under(oldRoot,file.path);
      if(Directory.Exists(target)||HasFileAncestor(target,oldRoot)) return;
      if(File.Exists(target)) using(var locked=LockFile(target)) {
        var current=FileSnapshot(oldRoot,target); if(current.sha256==file.sha256&&current.bytes==file.bytes) return;
        SavePersonalCopy(target,current,"旧版文件");
        PayloadFile original;
        // Keep the old side on a true two-sided edit or collision with an old
        // managed program file. Both readable versions now exist independently.
        if(oldOwned.ContainsKey(file.path)||!baseline.TryGetValue(file.path,out original)||current.bytes!=original.bytes||current.sha256!=original.sha256) return;
        // Both readable originals have already been durably saved. Write via a
        // duplicate of the locked object handle; path replacement is forbidden.
        CopyIntoLockedFile(locked,source,target,file);
      }
      else CopyVerified(source,target,file);
      FileBoundary("rollback.afterPersonalMerge");
    }
    static void PreserveFailedCandidates(string oldRoot,bool remove) {
      foreach(string candidate in Directory.GetDirectories(marker,"failed-*")) PreserveCandidate(candidate,oldRoot,remove);
    }
    static void PreserveCandidate(string candidate,string oldRoot,bool remove) {
      CheckAncestors(candidate); var owned=ReadOwnedPayload(candidate);
      if(owned.id!=journal.id) throw new IOException("候选恢复目录身份不符，保留全部文件。");
      var managed=owned.files.ToDictionary(file=>file.path,StringComparer.OrdinalIgnoreCase);
      var baseline=journal.preservedFiles.ToDictionary(file=>file.path,StringComparer.OrdinalIgnoreCase);
      IDictionary<string,PayloadFile> oldOwned=new Dictionary<string,PayloadFile>(StringComparer.OrdinalIgnoreCase);
      if(oldRoot!=null&&File.Exists(Path.Combine(oldRoot,OwnedFile))) oldOwned=ReadOwnedPayload(oldRoot).files.ToDictionary(file=>file.path,StringComparer.OrdinalIgnoreCase);
      foreach(string path in AllFiles(candidate).ToArray()) {
        string relative=path.Substring(candidate.Length+1).Replace('\\','/');
        if(relative==OwnedFile||relative==TokenFile) continue;
        using(var locked=LockFile(path)) {
          var file=FileSnapshot(candidate,path); PayloadFile expected;
          bool qaShortcut=IsQa&&ShortcutPaths().Any(shortcut=>String.Equals(shortcut.Substring(install.Length+1).Replace('\\','/'),relative,StringComparison.OrdinalIgnoreCase));
          bool unchanged=qaShortcut||(managed.TryGetValue(relative,out expected)&&expected.bytes==file.bytes&&expected.sha256==file.sha256);
          if(!unchanged) unchanged=baseline.TryGetValue(relative,out expected)&&expected.bytes==file.bytes&&expected.sha256==file.sha256;
          if(!unchanged) RestorePersonalFile(path,file,oldRoot,oldOwned,baseline);
          if(remove) { FileBoundary("rollback.beforeCandidateDelete"); DeleteLockedFile(locked,path); }
        }
      }
      var managedDirectories=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach(var file in owned.files) {
        string parent=Path.GetDirectoryName(file.path.Replace('/',Path.DirectorySeparatorChar));
        while(!String.IsNullOrEmpty(parent)) {managedDirectories.Add(parent.Replace('\\','/'));parent=Path.GetDirectoryName(parent);}
      }
      foreach(string path in Directory.GetDirectories(candidate,"*",SearchOption.AllDirectories)) {
        string relative=path.Substring(candidate.Length+1).Replace('\\','/');
        if(managedDirectories.Contains(relative)||journal.preservedDirectories.Contains(relative,StringComparer.OrdinalIgnoreCase)||(IsQa&&relative.StartsWith("_qa",StringComparison.OrdinalIgnoreCase))) continue;
        string backup=Under(Path.Combine(PersonalRecoveryRoot(),"候选文件"),relative); CheckAncestors(backup);
        if(File.Exists(backup)) throw new IOException("个人目录恢复位置含文件，保留候选目录。");
        Directory.CreateDirectory(backup);
        if(oldRoot!=null) {string target=Under(oldRoot,relative);if(!File.Exists(target)&&!HasFileAncestor(target,oldRoot)) {CheckAncestors(target);Directory.CreateDirectory(target);}}
      }
      if(!remove) return;
      // No recursive deletion of a candidate that can receive personal writes.
      // Unexpected concurrent files cause a retry while its identity survives.
      if(AllFiles(candidate).Any(path=>path!=Path.Combine(candidate,OwnedFile)&&path!=Path.Combine(candidate,TokenFile))) throw new IOException("候选目录出现新的文件，保留身份并重试恢复。");
      foreach(string directory in Directory.GetDirectories(candidate,"*",SearchOption.AllDirectories).OrderByDescending(path=>path.Length)) Directory.Delete(directory,false);
      string terminal=Path.Combine(marker,"candidate-cleanup-"+Guid.NewGuid().ToString("N")); Directory.Move(candidate,terminal);
      FileBoundary("rollback.afterCandidateRetire");
      if(Directory.GetDirectories(terminal).Length!=0||Directory.GetFiles(terminal).Any(path=>Path.GetFileName(path)!=OwnedFile&&Path.GetFileName(path)!=TokenFile)) throw new IOException("候选清理目录含新增个人内容，保留目录供恢复。");
      DeleteCandidateIdentity(terminal); Directory.Delete(terminal,false);
    }
    static void CleanupCandidateTerminals() {
      foreach(string terminal in Directory.GetDirectories(marker,"candidate-cleanup-*")) {
        CheckAncestors(terminal); AllFiles(terminal).ToArray();
        if(Directory.GetDirectories(terminal).Length!=0||Directory.GetFiles(terminal).Any(path=>Path.GetFileName(path)!=OwnedFile&&Path.GetFileName(path)!=TokenFile)) throw new IOException("候选清理残留中有未保存个人内容，保留并停止："+terminal);
        DeleteCandidateIdentity(terminal); Directory.Delete(terminal,false);
      }
    }
    static void DeleteCandidateIdentity(string terminal) {
      var locks=new Dictionary<string,SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
      try {
        foreach(string name in new[]{OwnedFile,TokenFile}) {string path=Path.Combine(terminal,name);if(File.Exists(path)) locks.Add(name,LockFile(path));}
        if(locks.ContainsKey(TokenFile)&&!TokenMatches(terminal,journal.id)) throw new IOException("候选清理残留身份改变。");
        if(locks.ContainsKey(OwnedFile)&&Json.Deserialize<OwnedPayload>(ReadSharedText(Path.Combine(terminal,OwnedFile),Encoding.UTF8)).id!=journal.id) throw new IOException("候选清理残留清单改变。");
        foreach(string name in new[]{OwnedFile,TokenFile}) if(locks.ContainsKey(name)) {FileBoundary("rollback.beforeCandidateIdentityDelete."+name);DeleteLockedFile(locks[name],Path.Combine(terminal,name));}
      } finally {foreach(var handle in locks.Values) handle.Dispose();}
    }
    static void RestoreRegistry() {
      Registry.CurrentUser.DeleteSubKeyTree(RegistryPath,false);
      if(!journal.hadRegistry) return;
      using(var root=Registry.CurrentUser.CreateSubKey(RegistryPath)) {
        foreach(string name in journal.registrySubkeys) if(name.Length>0) using(root.CreateSubKey(name)) {}
        foreach(var value in journal.registry) {
          using(var key=value.key.Length==0?Registry.CurrentUser.OpenSubKey(RegistryPath,true):root.CreateSubKey(value.key)) {
            var kind=(RegistryValueKind)value.kind; object data;
            if(kind==RegistryValueKind.Binary||kind==RegistryValueKind.None) data=Convert.FromBase64String(value.binary);
            else if(kind==RegistryValueKind.MultiString) data=value.strings;
            else if(kind==RegistryValueKind.String||kind==RegistryValueKind.ExpandString) data=value.text;
            else if(kind==RegistryValueKind.DWord) data=unchecked((int)value.number);
            else data=value.number;
            key.SetValue(value.name,data,kind); key.Flush();
          }
        }
        root.Flush();
      }
    }
    static bool RegistryMatchesSnapshot() {
      var current=new Journal();
      using(var key=Registry.CurrentUser.OpenSubKey(RegistryPath,false)) { current.hadRegistry=key!=null; if(key!=null) CaptureRegistry(key,"",current); }
      return current.hadRegistry==journal.hadRegistry&&Json.Serialize(current.registrySubkeys)==Json.Serialize(journal.registrySubkeys)&&Json.Serialize(current.registry)==Json.Serialize(journal.registry);
    }
    static void CleanupCommitted() {
      if(!TokenMatches(install,journal.id)) throw new IOException("已提交候选身份改变，保留恢复目录。");
      DeleteOwnedTree(marker); journal=null;
    }
    static void DeleteOwnedTree(string root) {
      if(Full(root)!=Full(marker)||!Full(root).StartsWith(install+".",StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid transaction cleanup path.");
      if(journal==null||(journal.phase!="Committed"&&journal.phase!="RolledBack")) throw new IOException("Only completed transactions can be cleaned.");
      string terminal=marker+".cleanup-"+journal.id;
      if(!Directory.Exists(root)) { if(Directory.Exists(terminal)) CleanupTerminalDirectory(terminal); return; }
      AllFiles(root).ToArray(); // Reject junctions before any deletion.
      var saved=LoadJournal(Path.Combine(root,"journal.json"));
      if(saved.id!=journal.id||saved.phase!=journal.phase) throw new IOException("Completed journal identity changed before cleanup.");
      if(journal.phase=="RolledBack") { PreserveFailedCandidates(journal.hadOld?install:null,true); CleanupCandidateTerminals(); }
      string old=Path.Combine(root,"old");
      if(journal.phase=="Committed"&&Directory.Exists(old)) {
        if(!journal.preservationVerified) throw new IOException("旧版恢复备份未验证个人文件保留，停止清理并保留全部备份。请先另行备份恢复目录。");
        var expected=journal.oldFiles.ToDictionary(file=>file.path,StringComparer.OrdinalIgnoreCase);
        foreach(string path in AllFiles(old)) {
          string relative=path.Substring(old.Length+1).Replace('\\','/'); PayloadFile file;
          if(!expected.TryGetValue(relative,out file)||new FileInfo(path).Length!=file.bytes||Hash(path)!=file.sha256) throw new IOException("旧备份含新增或修改文件，保留备份并停止清理："+relative);
        }
        foreach(string path in AllFiles(old).ToArray()) using(var locked=LockFile(path)) {
          string relative=path.Substring(old.Length+1).Replace('\\','/'); PayloadFile file;
          if(!expected.TryGetValue(relative,out file)||new FileInfo(path).Length!=file.bytes||Hash(path)!=file.sha256) throw new IOException("旧备份含新增或修改文件，保留备份并停止清理："+relative);
          FileBoundary("cleanup.beforeOldFileDelete"); DeleteLockedFile(locked,path);
        }
        foreach(string directory in Directory.GetDirectories(old,"*",SearchOption.AllDirectories).OrderByDescending(path=>path.Length)) Directory.Delete(directory,false);
        Directory.Delete(old,false);
      }
      // Keep the flushed terminal phase while children are removed. A lock or
      // interruption can therefore be retried without restoring deleted backups.
      foreach(string directory in Directory.GetDirectories(root)) Directory.Delete(directory,true);
      foreach(string file in Directory.GetFiles(root)) if(!String.Equals(Path.GetFileName(file),"journal.json",StringComparison.OrdinalIgnoreCase)) File.Delete(file);
      FileBoundary("cleanup.beforeMove"); Directory.Move(root,terminal);
      CleanupTerminalDirectory(terminal);
    }
    static void CleanupTerminalDirectories() {
      string parent=Path.GetDirectoryName(marker);
      if(!Directory.Exists(parent)) return;
      foreach(string directory in Directory.GetDirectories(parent,Path.GetFileName(marker)+".cleanup-*")) CleanupTerminalDirectory(directory);
    }
    static void CleanupTerminalDirectory(string root) {
      string prefix=marker+".cleanup-"; Guid id;
      if(!Full(root).StartsWith(prefix,StringComparison.OrdinalIgnoreCase)||!Guid.TryParseExact(Full(root).Substring(prefix.Length),"N",out id)) throw new IOException("Invalid terminal cleanup directory.");
      CheckAncestors(root);
      var entries=Directory.GetFileSystemEntries(root);
      string path=Path.Combine(root,"journal.json");
      if(entries.Any(entry=>!String.Equals(entry,path,StringComparison.OrdinalIgnoreCase))) throw new IOException("Terminal cleanup directory contains unexpected files.");
      if(File.Exists(path)) using(var locked=LockFile(path)) {
        if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0) throw new IOException("Terminal journal cannot be a link.");
        var state=LoadJournal(path);
        if(state.id!=id.ToString("N")||(state.phase!="Committed"&&state.phase!="RolledBack")) throw new IOException("Terminal cleanup journal is not complete.");
        FileBoundary("cleanup.beforeJournalDelete"); DeleteLockedFile(locked,path);
      }
      FileBoundary("cleanup.afterJournalDelete");
      // An empty, strictly named terminal sibling is safe to remove even if a
      // previous process exited between deleting the final journal and directory.
      Directory.Delete(root,false);
    }
    static string Hash(string file) { using(var stream=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) using(var hash=SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-","").ToLowerInvariant(); }
    static void CreateShortcut(string path,string target) {
      var link=(IShellLink)new ShellLink();
      try { link.SetPath(target); link.SetWorkingDirectory(install); link.SetDescription("简账"); link.SetIconLocation(Path.Combine(install,"jianzhang.exe"),0); ((IPersistFile)link).Save(path,true); }
      finally { Marshal.FinalReleaseComObject(link); }
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool SetFileInformationByHandle(SafeFileHandle file,int information,ref byte data,uint size);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool DuplicateHandle(IntPtr sourceProcess,SafeFileHandle source,IntPtr targetProcess,out SafeFileHandle target,uint access,[MarshalAs(UnmanagedType.Bool)] bool inherit,uint options);
    [ComImport,Guid("00021401-0000-0000-C000-000000000046")] class ShellLink {}
    [ComImport,Guid("000214F9-0000-0000-C000-000000000046"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IShellLink {
      void GetPath([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder file,int length,IntPtr data,uint flags);
      void GetIDList(out IntPtr id); void SetIDList(IntPtr id);
      void GetDescription([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int length); void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
      void GetWorkingDirectory([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int length); void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
      void GetArguments([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int length); void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
      void GetHotkey(out short key); void SetHotkey(short key); void GetShowCmd(out int command); void SetShowCmd(int command);
      void GetIconLocation([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder file,int length,out int index); void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string file,int index);
      void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path,uint reserved); void Resolve(IntPtr window,uint flags); void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
  }
}
