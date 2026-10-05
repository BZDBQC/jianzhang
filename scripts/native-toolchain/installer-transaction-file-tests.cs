// Isolated file-system tests. This entry point never runs installer Main,
// preflight, Registry APIs, or shortcut creation.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;

namespace JianzhangInstaller {
  internal static class FileTests {
    static int passed;
    static readonly BindingFlags PrivateStatic=BindingFlags.Static|BindingFlags.NonPublic;
    static void Set(string name,object value) { typeof(Program).GetField(name,PrivateStatic).SetValue(null,value); }
    static object Invoke(string name,params object[] args) {
      try { return typeof(Program).GetMethod(name,BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,args); }
      catch(TargetInvocationException error) { ExceptionDispatchInfo.Capture(error.InnerException).Throw(); throw; }
    }
    static void Reject(Action action,string name) {
      bool rejected=false;
      try { action(); } catch(InvalidDataException) { rejected=true; } catch(IOException) { rejected=true; } catch(UnauthorizedAccessException) { rejected=true; } catch(System.ComponentModel.Win32Exception) { rejected=true; }
      if(!rejected) throw new Exception("Expected failure: "+name);
      passed++;
    }
    static Journal Setup(string root,string phase) {
      Directory.CreateDirectory(root);
      string install=Path.Combine(root,"client"); Directory.CreateDirectory(Path.Combine(install,"data"));
      if(!File.Exists(Path.Combine(install,"jianzhang.exe"))) File.WriteAllText(Path.Combine(install,"jianzhang.exe"),"complete old application");
      if(!File.Exists(Path.Combine(install,"data","app.so"))) File.WriteAllText(Path.Combine(install,"data","app.so"),"complete old application data");
      string marker=install+".__jianzhang_transaction";
      var state=new Journal {id=Guid.NewGuid().ToString("N"),install=install,registryKey=(string)typeof(Program).GetField("RegistryPath",PrivateStatic).GetRawConstantValue(),phase=phase,hadOld=true};
      foreach(string file in Directory.GetFiles(install,"*",SearchOption.AllDirectories)) state.oldFiles.Add(new PayloadFile {path=file.Substring(install.Length+1).Replace('\\','/'),bytes=new FileInfo(file).Length,sha256=(string)Invoke("Hash",file)});
      Set("install",install); Set("marker",marker); Set("journalPath",Path.Combine(marker,"journal.json")); Set("journal",state); Set("fileTestFault",null);
      return state;
    }
    static void AssertOld(Journal state) { Invoke("CheckFiles",state.install,state.oldFiles,true); }
    sealed class JournalFixture {
      internal Journal state;
      internal UninstallRecord uninstall;
      internal string path, boundary, oldHash;
      internal PayloadFile[] payload;
      internal JournalFixture(string root,bool removing) {
        if(removing) {
          state=SeedOwned(root); Invoke("BeginUninstall");
          uninstall=(UninstallRecord)Invoke("ReadUninstallRecord");
          path=Path.Combine(state.install+".__jianzhang_uninstall","journal.json");
          boundary="uninstall.journal.beforeReplace";
          uninstall.phase="Completed";
        } else {
          state=Setup(root,"Preparing"); Directory.CreateDirectory(state.install+".__jianzhang_transaction");
          Invoke("Save"); path=Path.Combine(state.install+".__jianzhang_transaction","journal.json");
          boundary="journal.beforeReplace"; state.phase="Prepared";
        }
        oldHash=(string)Invoke("Hash",path); payload=Snapshot(state.install);
      }
      internal void Save() { if(uninstall==null) Invoke("Save"); else Invoke("SaveUninstallRecord",path,uninstall); }
      internal void AssertPayload() { Invoke("CheckFiles",state.install,payload,true); }
      internal void AssertNew(string file) {
        var json=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(file,Encoding.UTF8));
        if((string)json["phase"]!=(uninstall==null?"Prepared":"Completed")) throw new Exception("New journal state was not fully serialized.");
      }
    }
    static IOException NativeIo(int code) { return new IOException("Controlled publication error "+code,unchecked((int)(0x80070000u|(uint)code))); }
    static void AssertPublicationError(Exception error,JournalFixture fixture,int attempts,int? native) {
      if(error==null||!error.Message.Contains("Operation=File.Replace")||!error.Message.Contains("Source="+fixture.path+".new")||!error.Message.Contains("Target="+fixture.path)||!error.Message.Contains("Attempt="+attempts+"/5")) throw new Exception("Publication error lost actual action, paths or attempt evidence.");
      if(error.InnerException==null) throw new Exception("Publication error lost its original I/O exception.");
      if(native.HasValue&&(!error.Message.Contains("HResult=0x"+unchecked((uint)NativeIo(native.Value).HResult).ToString("X8"))||!error.Message.Contains("NativeError="+native.Value))) throw new Exception("Publication error lost its original native HRESULT.");
    }
    static void JournalTransient(string root,bool removing,int code,int failures) {
      var fixture=new JournalFixture(root,removing); int attempts=0;
      Set("fileTestFault",new Action<string>(delegate(string point){ if(point==fixture.boundary&&++attempts<=failures) throw NativeIo(code); }));
      try { fixture.Save(); } finally { Set("fileTestFault",null); }
      if(attempts!=failures+1||File.Exists(fixture.path+".new")) throw new Exception("Transient publication did not retry exactly or consume only its staged file.");
      fixture.AssertNew(fixture.path); fixture.AssertPayload(); passed++;
    }
    static void JournalPersistent(string root,bool removing,int code,int expectedAttempts) {
      var fixture=new JournalFixture(root,removing); int attempts=0; Exception rejected=null;
      Set("fileTestFault",new Action<string>(delegate(string point){ if(point==fixture.boundary){attempts++;throw NativeIo(code);} }));
      try { try {fixture.Save();}catch(IOException error){rejected=error;} } finally { Set("fileTestFault",null); }
      AssertPublicationError(rejected,fixture,expectedAttempts,code);
      if(attempts!=expectedAttempts||(string)Invoke("Hash",fixture.path)!=fixture.oldHash) throw new Exception("Persistent journal failure changed old bytes or exceeded its retry limit.");
      fixture.AssertNew(fixture.path+".new"); fixture.AssertPayload();
      fixture.Save(); fixture.AssertNew(fixture.path); fixture.AssertPayload(); passed++;
    }
    static void JournalUnknown(string root,bool ordinary) {
      var fixture=new JournalFixture(root,false); int attempts=0; Exception rejected=null;
      var original=ordinary?new IOException("Ordinary non-native I/O failure"):new IOException("Unknown facility with deceptive low 16-bit native code",unchecked((int)0x81230497u));
      Set("fileTestFault",new Action<string>(delegate(string point){if(point==fixture.boundary){attempts++;throw original;}}));
      try {try {fixture.Save();}catch(IOException error){rejected=error;}} finally {Set("fileTestFault",null);}
      AssertPublicationError(rejected,fixture,1,null);
      if(attempts!=1||!Object.ReferenceEquals(rejected.InnerException,original)||!rejected.Message.Contains("NativeError=unavailable")||(string)Invoke("Hash",fixture.path)!=fixture.oldHash) throw new Exception("Unknown HRESULT was reinterpreted as a transient Win32 error.");
      fixture.AssertNew(fixture.path+".new");fixture.AssertPayload();passed++;
    }
    static void JournalNameChanged(string root,int code,bool removeSource) {
      var fixture=new JournalFixture(root,false); int attempts=0; Exception rejected=null; string displaced=fixture.path+".displaced";
      Set("fileTestFault",new Action<string>(delegate(string point){if(point==fixture.boundary){attempts++;if(removeSource)File.Delete(fixture.path+".new");else File.Move(fixture.path,displaced);throw NativeIo(code);}}));
      try {try{fixture.Save();}catch(IOException error){rejected=error;}}finally{Set("fileTestFault",null);}
      AssertPublicationError(rejected,fixture,1,code);
      if(attempts!=1||(string)Invoke("Hash",removeSource?fixture.path:displaced)!=fixture.oldHash||(!removeSource&&File.Exists(fixture.path))) throw new Exception("Changed publication names caused unsafe retry, recreation or old-journal loss.");
      if(!removeSource)fixture.AssertNew(fixture.path+".new");fixture.AssertPayload();passed++;
    }
    static void JournalNativeLock(string root,bool releaseLock) {
      var fixture=new JournalFixture(root,false); int attempts=0;Exception rejected=null;
      var signal=new ManualResetEvent(false);var held=new FileStream(fixture.path,FileMode.Open,FileAccess.Read,FileShare.Read);
      Thread release=null;
      if(releaseLock){release=new Thread(delegate(){signal.WaitOne(5000);Thread.Sleep(75);held.Dispose();});release.IsBackground=true;release.Start();}
      Set("fileTestFault",new Action<string>(delegate(string point){if(point==fixture.boundary){attempts++;signal.Set();}}));
      try {try{fixture.Save();}catch(IOException error){rejected=error;}}
      finally{Set("fileTestFault",null);signal.Set();if(release!=null&&!release.Join(2000))throw new Exception("Owned lock-release thread did not finish.");held.Dispose();signal.Dispose();}
      if(releaseLock){if(rejected!=null)throw rejected;if(attempts<2||attempts>5)throw new Exception("Released real journal lock was not retried within its limit.");fixture.AssertNew(fixture.path);}
      else{AssertPublicationError(rejected,fixture,5,null);if(attempts!=5||(string)Invoke("Hash",fixture.path)!=fixture.oldHash)throw new Exception("Persistent real journal lock changed old bytes or retry count.");fixture.AssertNew(fixture.path+".new");}
      fixture.AssertPayload();passed++;
    }
    static void JournalReadonly(string root) {
      var fixture=new JournalFixture(root,false);int attempts=0;Exception rejected=null;
      File.SetAttributes(fixture.path,FileAttributes.ReadOnly);
      Set("fileTestFault",new Action<string>(delegate(string point){if(point==fixture.boundary)attempts++;}));
      try{try{fixture.Save();}catch(IOException error){rejected=error;}}
      finally{Set("fileTestFault",null);File.SetAttributes(fixture.path,FileAttributes.Normal);}
      AssertPublicationError(rejected,fixture,1,5);
      if(attempts!=1||(string)Invoke("Hash",fixture.path)!=fixture.oldHash)throw new Exception("Read-only journal was retried or modified.");
      fixture.AssertNew(fixture.path+".new");fixture.AssertPayload();passed++;
    }
#if INSTALLER_QA
    static void JournalDiagnostic(string root,bool blocked) {
      var fixture=new JournalFixture(root,false);int attempts=0;Exception rejected=null;
      Set("config",new Config{version="2.0.0",qaRoot=root,files=new PayloadFile[0]});
      string log=Path.Combine(root,"journal-publication-errors.jsonl");if(blocked)Directory.CreateDirectory(log);
      var original=NativeIo(1175);
      Set("fileTestFault",new Action<string>(delegate(string point){if(point==fixture.boundary&&++attempts<=2)throw original;}));
      try{try{fixture.Save();}catch(IOException error){rejected=error;}}finally{Set("fileTestFault",null);}
      if(blocked){
        AssertPublicationError(rejected,fixture,1,1175);
        if(attempts!=1||!Object.ReferenceEquals(rejected.InnerException,original)||!rejected.Message.Contains("QA diagnostic write failure")||!(rejected.Data["QA diagnostic error"] is Exception)||(string)Invoke("Hash",fixture.path)!=fixture.oldHash)throw new Exception("Diagnostic failure concealed the original publication error or continued retrying.");
        fixture.AssertNew(fixture.path+".new");
      }else{
        if(rejected!=null)throw rejected;
        string[] lines=File.ReadAllLines(log,Encoding.UTF8);if(lines.Length!=2||attempts!=3)throw new Exception("QA diagnostic log lost actual retry events.");
        for(int i=0;i<lines.Length;i++){
          var record=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(lines[i]);
          if((string)record["operation"]!="File.Replace"||(string)record["source"]!=fixture.path+".new"||(string)record["target"]!=fixture.path||Convert.ToInt32(record["attempt"])!=i+1||(string)record["hresult"]!="0x80070497"||Convert.ToInt32(record["nativeError"])!=1175||!(bool)record["retry"])throw new Exception("QA diagnostic log did not retain actual action/path/HRESULT data.");
        }
        fixture.AssertNew(fixture.path);
      }
      fixture.AssertPayload();passed++;
    }
#endif
    static void JournalPublicationCases(string root,bool collectFailures) {
      var cases=new List<KeyValuePair<string,Action>>();
      foreach(int failures in new[]{1,2,4}){int count=failures;cases.Add(new KeyValuePair<string,Action>("transient1175-"+count,delegate{JournalTransient(Path.Combine(root,"t1175-"+count),false,1175,count);}));}
      foreach(int code in new[]{32,33}){int value=code;cases.Add(new KeyValuePair<string,Action>("transient-"+value,delegate{JournalTransient(Path.Combine(root,"t"+value),false,value,2);}));}
      foreach(int code in new[]{32,33,1175}){int value=code;cases.Add(new KeyValuePair<string,Action>("persistent-"+value,delegate{JournalPersistent(Path.Combine(root,"p"+value),false,value,5);}));}
      foreach(int code in new[]{5,112,1176,1177}){int value=code;cases.Add(new KeyValuePair<string,Action>("immediate-"+value,delegate{JournalPersistent(Path.Combine(root,"i"+value),false,value,1);}));}
      cases.Add(new KeyValuePair<string,Action>("unknown-facility",delegate{JournalUnknown(Path.Combine(root,"unknown"),false);}));
      cases.Add(new KeyValuePair<string,Action>("ordinary-io",delegate{JournalUnknown(Path.Combine(root,"ordinary"),true);}));
      foreach(int code in new[]{1175,1176,1177}){int value=code;cases.Add(new KeyValuePair<string,Action>("moved-target-"+value,delegate{JournalNameChanged(Path.Combine(root,"m"+value),value,false);}));}
      cases.Add(new KeyValuePair<string,Action>("missing-staged1175",delegate{JournalNameChanged(Path.Combine(root,"missing"),1175,true);}));
      cases.Add(new KeyValuePair<string,Action>("uninstall-transient1175",delegate{JournalTransient(Path.Combine(root,"ut"),true,1175,2);}));
      cases.Add(new KeyValuePair<string,Action>("uninstall-persistent1175",delegate{JournalPersistent(Path.Combine(root,"up"),true,1175,5);}));
      cases.Add(new KeyValuePair<string,Action>("released-real-lock",delegate{JournalNativeLock(Path.Combine(root,"rl"),true);}));
      cases.Add(new KeyValuePair<string,Action>("persistent-real-lock",delegate{JournalNativeLock(Path.Combine(root,"pl"),false);}));
      cases.Add(new KeyValuePair<string,Action>("read-only-journal",delegate{JournalReadonly(Path.Combine(root,"ro"));}));
      int failed=0;
      foreach(var test in cases){try{test.Value();Console.WriteLine("JOURNAL_CASE PASS "+test.Key);}catch(Exception error){if(!collectFailures)throw;failed++;Console.Error.WriteLine("JOURNAL_CASE FAIL "+test.Key+" "+error);}}
      if(failed>0)throw new Exception("Journal publication regressions failed="+failed+" total="+cases.Count);
    }
    static void PublishFailure(string root,string boundary) {
      var state=Setup(root,"Preparing");
      Set("fileTestFault",new Action<string>(delegate(string point) { if(point==boundary) throw new IOException("Injected file-only fault: "+point); }));
      try { Reject(delegate { Invoke("PublishInitialJournal"); },boundary); }
      finally { Set("fileTestFault",null); }
      string marker=state.install+".__jianzhang_transaction";
      if(Directory.Exists(marker)) throw new Exception("Incomplete initial journal was published at "+boundary);
      AssertOld(state);
      state.id=Guid.NewGuid().ToString("N"); Invoke("PublishInitialJournal"); Invoke("ReadJournal");
      if(!File.Exists(Path.Combine(marker,"journal.json"))) throw new Exception("Next initial publication failed.");
      AssertOld(state); passed++;
    }
    static void PublishCrash(string root,string boundary) {
      var original=Setup(root,"Preparing");
      var child=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"--publish-child \""+root+"\" "+boundary) {UseShellExecute=false,CreateNoWindow=true};
      using(var process=Process.Start(child)) {
        if(!process.WaitForExit(10000)) { process.Kill(); throw new Exception("File-only crash child timed out."); }
        if(process.ExitCode!=99) throw new Exception("File-only crash child failed: "+process.ExitCode);
      }
      string install=Path.Combine(root,"client"),marker=install+".__jianzhang_transaction";
      if(Directory.Exists(marker)) throw new Exception("Crash exposed an incomplete marker.");
      var preparing=Directory.GetDirectories(root,"client.__jianzhang_transaction.preparing-*");
      if(preparing.Length!=1) throw new Exception("Missing unpublished crash fixture.");
      if(boundary=="publish.beforeMove"&&!File.Exists(Path.Combine(preparing[0],"journal.json"))) throw new Exception("Pre-publication journal was not completely flushed.");
      AssertOld(original);
      string executable=(string)Invoke("Hash",Path.Combine(install,"jianzhang.exe"));
      var state=Setup(root,"Preparing");
      if((string)Invoke("Hash",Path.Combine(install,"jianzhang.exe"))!=executable) throw new Exception("Crash changed the old application.");
      AssertOld(state); Invoke("PublishInitialJournal"); Invoke("ReadJournal"); AssertOld(state); passed++;
    }
    static void CleanupLocked(string root,string phase) {
      var state=Setup(root,phase); string marker=state.install+".__jianzhang_transaction";
      Directory.CreateDirectory(Path.Combine(marker,"stage"));
      Invoke("Save");
      string locked=Path.Combine(marker,"stage","locked.bin"); File.WriteAllText(locked,"locked incomplete candidate");
      File.WriteAllText(Path.Combine(marker,"stage","partial.bin"),"unlocked incomplete candidate");
      using(var handle=new FileStream(locked,FileMode.Open,FileAccess.Read,FileShare.Read)) {
        Reject(delegate { Invoke("DeleteOwnedTree",marker); },phase+" cleanup locked child");
        if(!File.Exists(Path.Combine(marker,"journal.json"))) throw new Exception("Cleanup lost its recovery journal.");
        Invoke("ReadJournal"); AssertOld(state);
      }
      // Exercise the file-only routine used by the RolledBack retry branch.
      // Never call Rollback itself: a future regression must not let this
      // isolated harness enter registration or shortcut recovery code.
      if(phase=="RolledBack") { state.registryTouched=true; Set("journal",state); Invoke("FinishRollbackCleanup"); }
      else Invoke("DeleteOwnedTree",marker);
      if(Directory.Exists(marker)||Directory.GetDirectories(root,"client.__jianzhang_transaction.cleanup-*").Length!=0) throw new Exception("Cleanup retry left a transaction directory.");
      AssertOld(state); passed++;
    }
    static void CleanupFailure(string root,string boundary) {
      var state=Setup(root,"RolledBack"); string marker=state.install+".__jianzhang_transaction";
      Directory.CreateDirectory(marker); Invoke("Save");
      Set("fileTestFault",new Action<string>(delegate(string point) { if(point==boundary) throw new IOException("Injected file-only fault: "+point); }));
      try { Reject(delegate { Invoke("DeleteOwnedTree",marker); },boundary); }
      finally { Set("fileTestFault",null); }
      AssertOld(state);
      if(boundary=="cleanup.beforeMove") {
        if(!File.Exists(Path.Combine(marker,"journal.json"))) throw new Exception("Failed retirement lost its journal.");
        Invoke("DeleteOwnedTree",marker);
      } else {
        if(Directory.Exists(marker)) throw new Exception("Terminal cleanup still exposes the active marker.");
        Invoke("CleanupTerminalDirectories");
      }
      if(Directory.Exists(marker)||Directory.GetDirectories(root,"client.__jianzhang_transaction.cleanup-*").Length!=0) throw new Exception("Terminal cleanup retry failed.");
      AssertOld(state); passed++;
    }
    static PayloadFile[] Snapshot(string root) {
      return Directory.GetFiles(root,"*",SearchOption.AllDirectories).Select(file=>new PayloadFile {path=file.Substring(root.Length+1).Replace('\\','/'),bytes=new FileInfo(file).Length,sha256=(string)Invoke("Hash",file)}).ToArray();
    }
    static Journal SeedOwned(string root) {
      var state=Setup(root,"Prepared");
      File.WriteAllText(Path.Combine(state.install,"Uninstall.exe"),"uninstaller 1");
      File.WriteAllText(Path.Combine(state.install,"README.txt"),"original managed guide");
      File.WriteAllText(Path.Combine(state.install,"obsolete.dll"),"obsolete managed library");
      Set("config",new Config {version="2.0.0",files=Snapshot(state.install).Where(file=>file.path!="Uninstall.exe").ToArray()});
      Invoke("WriteOwnedPayload",state.install); Invoke("ReadOwnedPayload",state.install);
      Directory.CreateDirectory(Path.Combine(state.install,"我的备份 空格")); Directory.CreateDirectory(Path.Combine(state.install,"空目录 保留"));
      File.WriteAllText(Path.Combine(state.install,"我的备份 空格","2026-10.json"),"{\"note\":\"用户备份\"}",Encoding.UTF8);
      File.WriteAllText(Path.Combine(state.install,"我的备份 空格","export.csv"),"备注,金额\r\n午餐,12.34",Encoding.UTF8);
      File.WriteAllBytes(Path.Combine(state.install,"我的备份 空格","export.xlsx"),new byte[]{80,75,3,4,17,0,99});
      File.WriteAllText(Path.Combine(state.install,"data","notes.json"),"personal notes in a managed parent",Encoding.UTF8);
      return state;
    }
    static Config Candidate(string generation,string extraPath) {
      var files=new List<PayloadFile>();
      foreach(string path in new[]{"jianzhang.exe","data/app.so","README.txt"}.Concat(extraPath==null?new string[0]:new[]{extraPath})) {
        byte[] bytes=Encoding.UTF8.GetBytes(generation+":"+path);
        using(var hash=System.Security.Cryptography.SHA256.Create()) files.Add(new PayloadFile {path=path,bytes=bytes.Length,sha256=BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-","").ToLowerInvariant()});
      }
      return new Config {version="2.0.0",files=files.ToArray()};
    }
    static Journal BeginUpgrade(string install,string generation,string extraPath) {
      string marker=install+".__jianzhang_transaction";
      var state=new Journal {id=Guid.NewGuid().ToString("N"),install=install,registryKey=(string)typeof(Program).GetField("RegistryPath",PrivateStatic).GetRawConstantValue(),phase="Prepared",hadOld=true};
      state.oldFiles.AddRange(Snapshot(install));
      Set("install",install); Set("marker",marker); Set("journalPath",Path.Combine(marker,"journal.json")); Set("journal",state); Set("config",Candidate(generation,extraPath)); Set("fileTestFault",null);
      Invoke("ValidateConfig");
      Invoke("ClassifyPreservedFiles",state); Invoke("PublishInitialJournal");
      string stage=Path.Combine(marker,"stage"); Directory.CreateDirectory(stage);
      foreach(var file in Candidate(generation,extraPath).files) { string path=Path.Combine(stage,file.path.Replace('/',Path.DirectorySeparatorChar)); Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllText(path,generation+":"+file.path,new UTF8Encoding(false)); }
      File.WriteAllText(Path.Combine(stage,"Uninstall.exe"),"uninstaller "+generation);
      return state;
    }
    static void RunPayload(Journal state) {
      var locks=new List<SafeFileHandle>();
      try { Invoke("CommitPayload",locks); }
      catch(Exception error) { throw new IOException("File-only payload failed in phase "+state.phase+": "+error.Message,error); }
      finally { foreach(var handle in locks) handle.Dispose(); }
    }
    static void AssertPersonalFiles(string install,IEnumerable<PayloadFile> extras) {
      Invoke("CheckFiles",install,extras,false);
      if(!Directory.Exists(Path.Combine(install,"空目录 保留"))) throw new Exception("Empty personal directory was lost.");
    }
    static void SuccessfulUpgrades(string root) {
      var seeded=SeedOwned(root); string install=seeded.install;
      var personal=Snapshot(install).Where(file=>file.path.StartsWith("我的备份 空格/",StringComparison.Ordinal)||file.path=="data/notes.json").ToArray();
      for(int index=1;index<=2;index++) {
        var state=BeginUpgrade(install,"generation-"+index,null); RunPayload(state);
        AssertPersonalFiles(install,personal);
        if(File.Exists(Path.Combine(install,"obsolete.dll"))) throw new Exception("Unchanged obsolete managed file was retained as personal data.");
        state.phase="Committed"; Invoke("Save"); Invoke("CleanupCommitted"); AssertPersonalFiles(install,personal);
        if(Directory.Exists(install+".__jianzhang_transaction")) throw new Exception("Successful old payload cleanup failed.");
        if(index==1) {
          File.AppendAllText(Path.Combine(install,"data","notes.json"),"\nupdated between upgrades",Encoding.UTF8);
          personal=Snapshot(install).Where(file=>file.path.StartsWith("我的备份 空格/",StringComparison.Ordinal)||file.path=="data/notes.json").ToArray();
        }
        passed++;
      }
      Invoke("CheckUninstallOwnership");
      var owned=(OwnedPayload)Invoke("ReadOwnedPayload",install);
      // Pure file removal only, corresponding to the verified owned payload
      // paths. Do not invoke NSIS, helper Main, registration or shortcuts.
      foreach(var file in owned.files) File.Delete(Path.Combine(install,file.path.Replace('/',Path.DirectorySeparatorChar)));
      File.Delete(Path.Combine(install,".jianzhang-install-id")); File.Delete(Path.Combine(install,".jianzhang-payload.json"));
      AssertPersonalFiles(install,personal); passed++;
    }
    static void PreservationRejected(string root,string collision,bool modifiedOwned) {
      var state=SeedOwned(root);
      if(modifiedOwned) File.AppendAllText(Path.Combine(state.install,"jianzhang.exe"),"personal replacement");
      var expected=Snapshot(state.install);
      Reject(delegate { BeginUpgrade(state.install,"collision",collision); },"personal payload collision");
      Invoke("CheckFiles",state.install,expected,true);
      if(Directory.Exists(state.install+".__jianzhang_transaction")) throw new Exception("Collision published or moved the old installation.");
      passed++;
    }
    static void PreservationLock(string root,bool injectCopyFailure) {
      var seeded=SeedOwned(root); var state=BeginUpgrade(seeded.install,"lock-fault",null);
      string file=Path.Combine(state.install,"我的备份 空格","export.csv");
      if(injectCopyFailure) Set("fileTestFault",new Action<string>(delegate(string point) { if(point=="preserve.beforeCopy") throw new IOException("Injected preservation copy fault."); }));
      try {
        if(injectCopyFailure) Reject(delegate { RunPayload(state); },"preservation copy failure");
        else using(var handle=new FileStream(file,FileMode.Open,FileAccess.ReadWrite,FileShare.None)) Reject(delegate { RunPayload(state); },"personal file lock");
      } finally { Set("fileTestFault",null); }
      Invoke("CheckFiles",state.install,state.oldFiles,true);
      if(Directory.Exists(Path.Combine(state.install+".__jianzhang_transaction","old"))) throw new Exception("Failed preservation moved the old payload.");
      state.phase="RolledBack"; Invoke("Save"); Invoke("FinishRollbackCleanup"); Invoke("CheckFiles",state.install,state.oldFiles,true); passed++;
    }
    static void OwnershipRejected(string root,bool tamperManifest) {
      var state=SeedOwned(root); string manifest=Path.Combine(state.install,".jianzhang-payload.json");
      if(tamperManifest) File.AppendAllText(manifest," "); else File.Delete(manifest);
      var expected=Snapshot(state.install); Set("config",Candidate("new",null));
      Reject(delegate { Invoke("ClassifyPreservedFiles",new Journal()); },tamperManifest?"changed ownership metadata":"legacy missing ownership metadata");
      Invoke("CheckFiles",state.install,expected,true); passed++;
    }
    static void ModifiedUninstallRejected(string root) {
      var state=SeedOwned(root); File.AppendAllText(Path.Combine(state.install,"README.txt"),"personal notes");
      var expected=Snapshot(state.install);
      Reject(delegate { Invoke("CheckUninstallOwnership"); },"modified managed file uninstall");
      Invoke("CheckFiles",state.install,expected,true); passed++;
    }
    static void LegacyBackupRejected(string root) {
      var state=Setup(root,"Committed"); string marker=state.install+".__jianzhang_transaction";
      Directory.CreateDirectory(Path.Combine(marker,"old"));
      string personal=Path.Combine(marker,"old","personal.json"); File.WriteAllText(personal,"legacy personal backup");
      Invoke("Save"); Reject(delegate { Invoke("DeleteOwnedTree",marker); },"unverified legacy backup cleanup");
      if(!File.Exists(personal)||!File.Exists(Path.Combine(marker,"journal.json"))) throw new Exception("Legacy backup was removed.");
      AssertOld(state); passed++;
    }
    static void ModifiedObsoletePreserved(string root) {
      var seeded=SeedOwned(root); string file=Path.Combine(seeded.install,"obsolete.dll");
      File.AppendAllText(file,"personal replacement bytes");
      var personal=Snapshot(seeded.install).Where(item=>item.path=="obsolete.dll").ToArray();
      var state=BeginUpgrade(seeded.install,"obsolete-removed",null); RunPayload(state);
      Invoke("CheckFiles",seeded.install,personal,false); state.phase="Committed"; Invoke("Save"); Invoke("CleanupCommitted");
      Invoke("CheckFiles",seeded.install,personal,false);
      var owned=(OwnedPayload)Invoke("ReadOwnedPayload",seeded.install);
      if(owned.files.Any(item=>item.path=="obsolete.dll")) throw new Exception("Personal replacement became an installer-owned file.");
      Invoke("CheckUninstallOwnership");
      foreach(var item in owned.files) File.Delete(Path.Combine(seeded.install,item.path.Replace('/',Path.DirectorySeparatorChar)));
      Invoke("CheckFiles",seeded.install,personal,false); passed++;
    }
    static void RaceRecovery(string root,string mode) {
      var seeded=SeedOwned(root); var state=BeginUpgrade(seeded.install,"stale-stage",null); FileStream editor=null;
      Set("fileTestFault",new Action<string>(delegate(string point) {
        if(point=="payload.afterUnlock") {
          if(mode=="edit") File.AppendAllText(Path.Combine(state.install,"data","notes.json"),"LATEST USER EDIT",Encoding.UTF8);
          if(mode=="add") File.WriteAllText(Path.Combine(state.install,"data","new personal.json"),"LATEST ADDED FILE",Encoding.UTF8);
          if(mode=="delete") File.Delete(Path.Combine(state.install,"我的备份 空格","export.csv"));
          if(mode=="move-lock") { editor=new FileStream(Path.Combine(state.install,"data","notes.json"),FileMode.Open,FileAccess.ReadWrite,FileShare.None); editor.Seek(0,SeekOrigin.End); byte[] value=Encoding.UTF8.GetBytes("LATEST EDIT WITH HANDLE"); editor.Write(value,0,value.Length); editor.Flush(true); }
        }
        if(point=="payload.beforeRelock"&&mode=="relock") editor=new FileStream(Path.Combine(state.install+".__jianzhang_transaction","old","data","notes.json"),FileMode.Open,FileAccess.ReadWrite,FileShare.None);
      }));
      try { Reject(delegate { RunPayload(state); },"unlock window "+mode); }
      finally { Set("fileTestFault",null); }
      Set("journal",null); Invoke("ReadJournal");
      if(mode=="relock") {
        Reject(delegate { Invoke("RestorePayload"); },"restore while editor still holds old directory");
        if(Directory.Exists(state.install)) throw new Exception("Blocked recovery falsely reported an installed old directory.");
      }
      if(editor!=null) editor.Dispose();
      string old=Path.Combine(state.install+".__jianzhang_transaction","old");
      var latest=Snapshot(Directory.Exists(old)?old:state.install);
      Invoke("RestorePayload"); Invoke("CheckFiles",state.install,latest,true);
      var restored=(Journal)typeof(Program).GetField("journal",PrivateStatic).GetValue(null);
      restored.phase="RolledBack"; Invoke("Save"); Invoke("FinishRollbackCleanup");
      Invoke("CheckFiles",state.install,latest,true);
      if(Directory.Exists(state.install+".__jianzhang_transaction")) throw new Exception("Recovery retry retained stale stage.");
      passed++;
    }
    static void InitializeUninstall(string root) {
      string install=Path.Combine(root,"client"); Set("install",install); Set("marker",install+".__jianzhang_transaction"); Set("journalPath",Path.Combine(install+".__jianzhang_transaction","journal.json")); Set("journal",null); Set("fileTestFault",null);
      OwnedPayload owned;
      if(Directory.Exists(install+".__jianzhang_uninstall")) owned=(OwnedPayload)Invoke("OwnedFromRecord",Invoke("ReadUninstallRecord"));
      else owned=(OwnedPayload)Invoke("ReadOwnedPayload",install);
      Set("config",new Config {version=owned.version,files=owned.files.Where(file=>file.path!="Uninstall.exe").ToArray()});
    }
    static PayloadFile[] PersonalSnapshot(string install) {
      return Snapshot(install).Where(file=>file.path.StartsWith("我的备份 空格/",StringComparison.Ordinal)||file.path=="data/notes.json").ToArray();
    }
    static void DeleteOrdinaryOwned(string install) {
      Invoke("DeleteUninstallPayload");
    }
    static void UninstallRetry(string root,string boundary,bool lockFile) {
      try {
      var state=SeedOwned(root); var personal=PersonalSnapshot(state.install); Invoke("BeginUninstall"); DeleteOrdinaryOwned(state.install);
      if(lockFile) {
        string name=boundary; using(var held=new FileStream(Path.Combine(state.install,name),FileMode.Open,FileAccess.Read,FileShare.Read)) Reject(delegate { Invoke("FinishUninstall"); },"uninstall locked "+name);
      } else {
        Set("fileTestFault",new Action<string>(delegate(string point) { if(point==boundary) throw new IOException("Injected uninstall file-only failure at "+point); }));
        try { Reject(delegate { Invoke("FinishUninstall"); },boundary); }
        finally { Set("fileTestFault",null); }
      }
      if(!File.Exists(Path.Combine(state.install,"Uninstall.exe"))) throw new Exception("Failed uninstall removed its retry entry.");
      AssertPersonalFiles(state.install,personal);
      InitializeUninstall(root); Invoke("CheckUninstallOwnership"); Invoke("BeginUninstall"); Invoke("FinishUninstall");
      if(File.Exists(Path.Combine(state.install,"Uninstall.exe"))||File.Exists(Path.Combine(state.install,".jianzhang-payload.json"))||File.Exists(Path.Combine(state.install,".jianzhang-install-id"))) throw new Exception("Uninstall retry did not finish identity removal.");
      AssertPersonalFiles(state.install,personal);
      Invoke("CleanupCompletedUninstall"); AssertPersonalFiles(state.install,personal); passed++;
      } catch(Exception error) {
        string details="Uninstall retry fixture="+root+" boundary="+boundary+" currentBinding="+(string)Invoke("ConfigBinding");
        if(Directory.Exists(Path.Combine(root,"client.__jianzhang_uninstall"))) details+=" recordBinding="+((UninstallRecord)Invoke("ReadUninstallRecord")).configBinding;
        throw new IOException(details,error);
      }
    }
    static void UninstallMissingRejected(string root) {
      var state=SeedOwned(root); File.Delete(Path.Combine(state.install,"data","app.so"));
      var expected=Snapshot(state.install);
      Reject(delegate { Invoke("CheckUninstallOwnership"); },"missing payload before durable begin");
      Reject(delegate { Invoke("BeginUninstall"); },"begin with missing payload");
      Invoke("CheckFiles",state.install,expected,true);
      if(Directory.Exists(state.install+".__jianzhang_uninstall")) throw new Exception("Untrusted missing payload became a trusted uninstall.");
    }
    static void UninstallLateFailure(string root) {
      var state=SeedOwned(root); var personal=PersonalSnapshot(state.install); Invoke("BeginUninstall"); DeleteOrdinaryOwned(state.install);
      // A pure file surrogate for a later NSIS shortcut deletion failure. The
      // actual shortcut/registration stage is intentionally not executed here.
      string link=Path.Combine(root,"owned-shortcut.fixture"); File.WriteAllText(link,"owned fixture");
      using(var held=new FileStream(link,FileMode.Open,FileAccess.Read,FileShare.Read)) Reject(delegate { File.Delete(link); },"late shortcut deletion lock surrogate");
      InitializeUninstall(root); Invoke("CheckUninstallOwnership"); File.Delete(link); Invoke("BeginUninstall"); Invoke("FinishUninstall"); AssertPersonalFiles(state.install,personal); passed++;
    }
    static void UninstallCrash(string root,string boundary) {
      var state=SeedOwned(root); var personal=PersonalSnapshot(state.install);
      if(boundary!="uninstall.beforePublish") { Invoke("BeginUninstall"); DeleteOrdinaryOwned(state.install); }
      var child=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"--uninstall-child \""+root+"\" "+boundary) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true};
      using(var process=Process.Start(child)) { if(!process.WaitForExit(10000)) {process.Kill();throw new Exception("Uninstall crash child timed out: "+boundary);} if(process.ExitCode!=99) throw new Exception("Uninstall crash child failed at "+boundary+" exit="+process.ExitCode+": "+process.StandardError.ReadToEnd()); }
      if(!File.Exists(Path.Combine(state.install,"Uninstall.exe"))) throw new Exception("Interrupted uninstall lost its retry entry.");
      InitializeUninstall(root); Invoke("BeginUninstall");
      if(boundary=="uninstall.beforePublish") DeleteOrdinaryOwned(state.install);
      Invoke("FinishUninstall"); AssertPersonalFiles(state.install,personal); passed++;
    }
    static void UninstallPartialRetry(string root) {
      var state=SeedOwned(root); var personal=PersonalSnapshot(state.install); Invoke("BeginUninstall"); int deleted=0;
      Set("fileTestFault",new Action<string>(delegate(string point) { if(point=="uninstall.beforeDeletePayload"&&++deleted==2) throw new IOException("Injected second owned file deletion failure."); }));
      try { Reject(delegate { Invoke("DeleteUninstallPayload"); },"partial owned payload deletion"); }
      finally { Set("fileTestFault",null); }
      if(deleted!=2) throw new Exception("Payload failure did not follow a successful deletion.");
      InitializeUninstall(root); Invoke("CheckUninstallOwnership"); Invoke("BeginUninstall"); Invoke("DeleteUninstallPayload"); Invoke("FinishUninstall");
      AssertPersonalFiles(state.install,personal); passed++;
    }
    static void UninstallChangedOwned(string root) {
      var state=SeedOwned(root); Invoke("BeginUninstall");
      string file=Path.Combine(state.install,"README.txt"); File.AppendAllText(file,"PERSONAL NOTES AFTER DURABLE BEGIN");
      var expected=Snapshot(state.install);
      Reject(delegate { Invoke("DeleteUninstallPayload"); },"modified managed file after durable begin");
      Invoke("CheckFiles",state.install,expected,true);
      string personal=Path.Combine(state.install,"my preserved guide.txt"); File.Move(file,personal);
      string hash=(string)Invoke("Hash",personal); Invoke("DeleteUninstallPayload"); Invoke("FinishUninstall");
      if(!File.Exists(personal)||(string)Invoke("Hash",personal)!=hash) throw new Exception("User-moved personal replacement was deleted.");
      passed++;
    }
    static void InitializeRollback(string root) {
      string install=Path.Combine(root,"client"); Set("install",install); Set("marker",install+".__jianzhang_transaction"); Set("journalPath",Path.Combine(install+".__jianzhang_transaction","journal.json")); Set("journal",null); Set("fileTestFault",null); Invoke("ReadJournal");
      if(typeof(Program).GetField("config",PrivateStatic).GetValue(null)==null) {
        // Fresh crash-test children need the same manifest input that real
        // installer Main loads before running any recovery command.
        var owned=(OwnedPayload)Invoke("ReadOwnedPayload",install);
        Set("config",new Config {version=owned.version,files=owned.files.Where(file=>file.path!="Uninstall.exe").ToArray()});
      }
    }
    static Journal LateCandidate(string root,string mode) {
      var seeded=SeedOwned(root); var state=BeginUpgrade(seeded.install,"candidate-late",null); RunPayload(state);
      if(mode!="unchanged") {
        File.AppendAllText(Path.Combine(state.install,"data","notes.json")," LATEST CANDIDATE EDIT",Encoding.UTF8);
        File.WriteAllText(Path.Combine(state.install,"我的新备份.json"),"LATEST NEW USER BACKUP",Encoding.UTF8);
        Directory.CreateDirectory(Path.Combine(state.install,"用户新增空目录"));
      }
      if(mode=="conflict"||mode=="unchanged") File.AppendAllText(Path.Combine(state.install+".__jianzhang_transaction","old","data","notes.json")," LATEST OLD-SIDE EDIT",Encoding.UTF8);
      if(mode=="modified-managed") File.AppendAllText(Path.Combine(state.install,"README.txt")," PERSONAL CONTENT IN MANAGED PATH",Encoding.UTF8);
      return state;
    }
    static bool ContainsHash(string root,string hash) {
      return Directory.Exists(root)&&Directory.GetFiles(root,"*",SearchOption.AllDirectories).Any(file=>(string)Invoke("Hash",file)==hash);
    }
    static string AttemptAtomicSave(string root,string path) {
      string pending=Path.Combine(root,"pending-editor-save.tmp"); File.WriteAllText(pending,"LATEST USER ATOMIC SAVE FOR "+Path.GetFileName(path),Encoding.UTF8);
      Reject(delegate {File.Replace(pending,path,null);},"atomic replacement under strict installer lock");
      if(!File.Exists(pending)) throw new Exception("Rejected editor save lost its pending bytes.");
      return pending;
    }
    static void AtomicDeleteObject(string root) {
      Directory.CreateDirectory(root); string path=Path.Combine(root,"managed.txt"); File.WriteAllText(path,"checked bytes",Encoding.UTF8);
      string before=(string)Invoke("Hash",path);
      using(var locked=(SafeFileHandle)Invoke("LockFile",path)) {
        AttemptAtomicSave(root,path);
        Reject(delegate {File.AppendAllText(path,"unverified mutation");},"write under strict installer lock");
        Reject(delegate {File.Move(path,Path.Combine(root,"renamed.txt"));},"rename under strict installer lock");
        if((string)Invoke("Hash",path)!=before) throw new Exception("Strict lock changed checked contents.");
        Invoke("DeleteLockedFile",locked,path);
      }
      if(File.Exists(path)||!File.Exists(Path.Combine(root,"pending-editor-save.tmp"))) throw new Exception("Handle deletion removed the editor's distinct pending file or retained the checked object."); passed++;
    }
    static void AtomicRollbackRetry(string root,string name,bool identity) {
      var state=LateCandidate(root,"edit"); string expected=(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"));
      string candidate=Path.Combine(state.install+".__jianzhang_transaction","failed-"+state.id); bool attempted=false; string pending=null;
      Set("fileTestFault",new Action<string>(delegate(string point) {
        if(attempted||point!=(identity?"rollback.beforeCandidateIdentityDelete."+name:"rollback.beforeCandidateDelete")) return;
        string path;
        if(identity) {string terminal=Directory.GetDirectories(state.install+".__jianzhang_transaction","candidate-cleanup-*").Single();path=Path.Combine(terminal,name);}
        else path=Path.Combine(candidate,name.Replace('/',Path.DirectorySeparatorChar));
        if(!File.Exists(path)) return;
        bool held=false; try {using(var probe=new FileStream(path,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete)) {}} catch(IOException) {held=true;}
        if(!held) return;
        attempted=true; pending=AttemptAtomicSave(root,path); throw new IOException("Editor save rejected; caller must retry with pending bytes retained.");
      }));
      try {Reject(delegate {CompleteFileRollback();},"rollback interrupted at rejected atomic save");} finally {Set("fileTestFault",null);}
      if(!attempted||pending==null||!File.Exists(pending)) throw new Exception("Atomic rollback test did not reach locked deletion.");
      InitializeRollback(root); CompleteFileRollback();
      if(!File.Exists(pending)||(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"))!=expected) throw new Exception("Atomic-save rollback retry lost actual or pending personal bytes."); passed++;
    }
    static void AtomicUninstallRetry(string root,string name) {
      var state=SeedOwned(root); Invoke("BeginUninstall");
      bool ordinary=name=="README.txt"; if(!ordinary) DeleteOrdinaryOwned(state.install);
      bool attempted=false; string pending=null,path=Path.Combine(state.install,name),before=(string)Invoke("Hash",Path.Combine(state.install,name));
      string boundary=ordinary?"uninstall.beforeDeletePayload":name=="Uninstall.exe"?"uninstall.beforeDeleteEntry":"uninstall.beforeDelete."+name;
      Set("fileTestFault",new Action<string>(delegate(string point) {
        if(attempted||point!=boundary||!File.Exists(path)) return;
        bool held=false; try {using(var probe=new FileStream(path,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete)) {}}catch(IOException) {held=true;}
        if(!held) return; attempted=true; pending=AttemptAtomicSave(root,path); throw new IOException("Editor atomic save rejected; retain uninstall retry state.");
      }));
      try {Reject(delegate {if(ordinary) Invoke("DeleteUninstallPayload");else Invoke("FinishUninstall");},"uninstall interrupted at rejected atomic save");}finally {Set("fileTestFault",null);}
      if(!attempted||!File.Exists(path)||(string)Invoke("Hash",path)!=before||pending==null||!File.Exists(pending)) throw new Exception("Rejected atomic save lost the checked file or pending replacement.");
      InitializeUninstall(root); Invoke("CheckUninstallOwnership"); Invoke("DeleteUninstallPayload"); Invoke("FinishUninstall");
      if(File.Exists(path)||!File.Exists(pending)) throw new Exception("Uninstall retry did not delete the checked object or lost separate editor bytes."); passed++;
    }
    static void SetBudgetConfig(string install,string extra) {
      Set("install",install);Set("config",Candidate("budget",extra));Set("failNth",0);Set("crashNth",0);Set("fileTestFault",null);
    }
    static void RejectBudgetUnchanged(Journal state,PayloadFile[] before,string[] siblings) {
      bool rejected=false;
      try {Invoke("ValidateConfig");}catch(IOException error) {if(!error.Message.Contains("过长")||!error.Message.Contains("默认")) throw;rejected=true;}
      if(!rejected) throw new Exception("An over-budget transaction was accepted.");
      Invoke("CheckFiles",state.install,before,true);
      string parent=Path.GetDirectoryName(state.install);
      if(!Directory.GetFileSystemEntries(parent).OrderBy(path=>path,StringComparer.Ordinal).SequenceEqual(siblings.OrderBy(path=>path,StringComparer.Ordinal))) throw new Exception("Budget rejection changed marker/backup siblings.");
      passed++;
    }
    static void BudgetReviewerInput(string root,bool existingMarker) {
      // Reproduce final payload 177 / retired identity 262 without entering a
      // transaction. Never shorten the input to disguise the original failure.
      Directory.CreateDirectory(root);
      int padding=163-root.Length-8;
      if(padding<1) throw new Exception("Use a fixture root below 155 characters for the exact 177/262 path-budget regression.");
      string fixture=Path.Combine(root,new string('r',padding)); var state=SeedOwned(fixture);
      if(state.install.Length!=163) throw new Exception("Exact reviewer input length was not reproduced.");
      SetBudgetConfig(state.install,null);
      var before=Snapshot(state.install); string marker=state.install+".__jianzhang_transaction",journal=Path.Combine(marker,"journal.json");
      if(existingMarker) {Directory.CreateDirectory(marker);File.WriteAllText(journal,"EXISTING RECOVERY MUST REMAIN",Encoding.UTF8);}
      string markerHash=existingMarker?(string)Invoke("Hash",journal):null;
      var siblings=Directory.GetFileSystemEntries(Path.GetDirectoryName(state.install));
      RejectBudgetUnchanged(state,before,siblings);
      if(existingMarker&&((string)Invoke("Hash",journal)!=markerHash||File.ReadAllText(journal)!="EXISTING RECOVERY MUST REMAIN")) throw new Exception("Early budget rejection touched the existing recovery journal.");
      if(!existingMarker&&Directory.Exists(marker)) throw new Exception("Early budget rejection created a marker.");
      int final=Candidate("budget",null).files.Max(file=>Path.Combine(state.install,file.path).Length);
      int retired=Path.Combine(marker,"candidate-cleanup-"+new string('0',32),".jianzhang-payload.json").Length;
      if(final!=177||retired!=262) throw new Exception("Reviewer path reproduction lost its original final/internal lengths."); passed++;
    }
    static void BudgetRelativeInput(string root,string kind) {
      var state=SeedOwned(root); string relative="nested/"+new string('p',Math.Max(20,220-state.install.Length-20))+"/notes.json";
      if(kind=="manifest") SetBudgetConfig(state.install,relative);
      else {
        string personal=Path.Combine(state.install,relative);Directory.CreateDirectory(Path.GetDirectoryName(personal));
        if(kind=="directory") Directory.CreateDirectory(personal); else File.WriteAllText(personal,"PERSONAL BYTES MUST REMAIN",Encoding.UTF8);
        SetBudgetConfig(state.install,null);
      }
      var before=Snapshot(state.install); var directories=Directory.GetDirectories(state.install,"*",SearchOption.AllDirectories).OrderBy(path=>path,StringComparer.Ordinal).ToArray();
      RejectBudgetUnchanged(state,before,Directory.GetFileSystemEntries(Path.GetDirectoryName(state.install)));
      if(!Directory.GetDirectories(state.install,"*",SearchOption.AllDirectories).OrderBy(path=>path,StringComparer.Ordinal).SequenceEqual(directories)) throw new Exception("Budget rejection changed personal directories."); passed++;
    }
    static void BudgetBoundaryTransaction(string root) {
      Directory.CreateDirectory(root);string accepted=null;
      for(int size=1;size<100;size++) {
        string fixture=Path.Combine(root,new string('b',size)),destination=Path.Combine(fixture,"client");SetBudgetConfig(destination,null);
        try {Invoke("ValidateConfig");accepted=fixture;}catch(IOException error) {if(!error.Message.Contains("过长")) throw;break;}
      }
      if(accepted==null) throw new Exception("Boundary regression needs a fixture root with room for a valid transaction.");
      var seeded=SeedOwned(accepted);SetBudgetConfig(seeded.install,null);Invoke("ValidateConfig");
      string retired=Path.Combine(seeded.install+".__jianzhang_transaction","candidate-cleanup-"+new string('0',32),".jianzhang-payload.json");
      if(retired.Length!=259) throw new Exception("Boundary test did not exercise the largest accepted retired identity path: "+retired.Length);
      var state=BeginUpgrade(seeded.install,"budget-boundary",null);RunPayload(state);
      File.AppendAllText(Path.Combine(state.install,"data","notes.json")," BOUNDARY LATE PERSONAL EDIT",Encoding.UTF8);
      string latest=(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"));InitializeRollback(accepted);CompleteFileRollback();
      if((string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"))!=latest||Directory.Exists(state.install+".__jianzhang_transaction")) throw new Exception("Largest accepted boundary rollback did not finish or lost user bytes.");
      InitializeUninstall(accepted);Invoke("ValidateConfig");Invoke("BeginUninstall");Invoke("DeleteUninstallPayload");Invoke("FinishUninstall");Invoke("CleanupCompletedUninstall");
      if((string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"))!=latest||File.Exists(Path.Combine(state.install,"Uninstall.exe"))) throw new Exception("Largest accepted boundary uninstall lost user bytes or failed completion.");passed++;
    }
    static void LateRollback(string root,string mode) {
      var state=LateCandidate(root,mode); string recovery=Path.Combine(root,"简账恢复-"+state.id);
      string candidateNote=(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"));
      string oldNote=(string)Invoke("Hash",Path.Combine(state.install+".__jianzhang_transaction","old","data","notes.json"));
      string newBackup=mode=="unchanged"?null:(string)Invoke("Hash",Path.Combine(state.install,"我的新备份.json"));
      string changedGuide=mode=="modified-managed"?(string)Invoke("Hash",Path.Combine(state.install,"README.txt")):null;
      InitializeRollback(root); Invoke("RestorePayload");
      var loaded=(Journal)typeof(Program).GetField("journal",PrivateStatic).GetValue(null); loaded.phase="RolledBack"; Invoke("Save"); Invoke("FinishRollbackCleanup");
      string actual=(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"));
      if(mode=="unchanged") {
        if(actual!=oldNote||Directory.Exists(recovery)) throw new Exception("Unchanged default personal copies caused a conflict or lost the newer old side.");
      } else {
        if(actual!=(mode=="conflict"?oldNote:candidateNote)) throw new Exception("Rollback did not preserve the intended newest personal note.");
        if((string)Invoke("Hash",Path.Combine(state.install,"我的新备份.json"))!=newBackup||!Directory.Exists(Path.Combine(state.install,"用户新增空目录"))) throw new Exception("Late personal file or empty directory was lost.");
        if(!ContainsHash(Path.Combine(recovery,"候选文件"),candidateNote)) throw new Exception("Candidate personal version has no readable verified backup.");
        if(mode=="conflict"&&!ContainsHash(Path.Combine(recovery,"旧版文件"),oldNote)) throw new Exception("Old-side conflict version has no readable verified backup.");
        if(changedGuide!=null&&!ContainsHash(Path.Combine(recovery,"候选文件"),changedGuide)) throw new Exception("Modified candidate managed-path content was lost.");
      }
      if(Directory.Exists(state.install+".__jianzhang_transaction")) throw new Exception("Rollback did not finish candidate cleanup.");
      var oldOwned=(OwnedPayload)Invoke("ReadOwnedPayload",state.install); Invoke("CheckFiles",state.install,oldOwned.files,false); passed++;
    }
    static void LateRollbackFailure(string root,string boundary,bool crash) {
      var state=LateCandidate(root,"edit"); string expected=(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json")); string backup=(string)Invoke("Hash",Path.Combine(state.install,"我的新备份.json"));
      if(crash) {
        var child=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"--rollback-child \""+root+"\" "+boundary) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true};
        using(var process=Process.Start(child)) {if(!process.WaitForExit(10000)) {process.Kill();throw new Exception("Rollback crash child timed out: "+boundary);}if(process.ExitCode!=99) throw new Exception("Rollback child failed at "+boundary+" exit="+process.ExitCode+": "+process.StandardError.ReadToEnd());}
      } else {
        bool reached=false; Set("fileTestFault",new Action<string>(delegate(string point) {if(point==boundary) {reached=true;throw new IOException("Injected late rollback fault "+point);}}));
        try { Reject(delegate { CompleteFileRollback(); },boundary); } finally {Set("fileTestFault",null);}
        if(!reached) throw new Exception("Late rollback fault boundary was not reached.");
      }
      InitializeRollback(root); CompleteFileRollback();
      if((string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"))!=expected||(string)Invoke("Hash",Path.Combine(state.install,"我的新备份.json"))!=backup) throw new Exception("Retry after late rollback failure lost the latest personal content.");
      if(Directory.Exists(state.install+".__jianzhang_transaction")) throw new Exception("Late rollback retry left an active transaction."); passed++;
    }
    static void CompleteFileRollback() {
      var state=(Journal)typeof(Program).GetField("journal",PrivateStatic).GetValue(null);
      if(state.phase!="RolledBack") {Invoke("RestorePayload");state.phase="RolledBack";Invoke("Save");}
      Invoke("FinishRollbackCleanup");
    }
    static void LateRollbackLock(string root) {
      var state=LateCandidate(root,"edit"); string hash=(string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"));
      using(var held=new FileStream(Path.Combine(state.install,"data","notes.json"),FileMode.Open,FileAccess.Read,FileShare.None)) Reject(delegate { Invoke("RestorePayload"); },"late personal editor holds candidate directory");
      InitializeRollback(root); CompleteFileRollback();
      if((string)Invoke("Hash",Path.Combine(state.install,"data","notes.json"))!=hash) throw new Exception("Late candidate lock retry lost the newest edit."); passed++;
    }
    static void FailedFirstInstallPersonal(string root) {
      Directory.CreateDirectory(root); string install=Path.Combine(root,"client"),marker=install+".__jianzhang_transaction";
      var state=new Journal {id=Guid.NewGuid().ToString("N"),install=install,registryKey=(string)typeof(Program).GetField("RegistryPath",PrivateStatic).GetRawConstantValue(),phase="Prepared",hadOld=false};
      var candidate=Candidate("first-install",null); Set("install",install);Set("marker",marker);Set("journalPath",Path.Combine(marker,"journal.json"));Set("journal",state);Set("config",candidate);Set("fileTestFault",null);Invoke("PublishInitialJournal");
      string stage=Path.Combine(marker,"stage");Directory.CreateDirectory(stage);
      foreach(var file in candidate.files) {string path=Path.Combine(stage,file.path.Replace('/',Path.DirectorySeparatorChar));Directory.CreateDirectory(Path.GetDirectoryName(path));File.WriteAllText(path,"first-install:"+file.path,new UTF8Encoding(false));}
      File.WriteAllText(Path.Combine(stage,"Uninstall.exe"),"first installer");RunPayload(state);
      string personal=Path.Combine(install,"用户首装期间备份.json"); File.WriteAllText(personal,"LATEST FIRST-INSTALL PERSONAL BYTES",Encoding.UTF8);string hash=(string)Invoke("Hash",personal);
      InitializeRollback(root);CompleteFileRollback();
      if(Directory.Exists(install)||!ContainsHash(Path.Combine(root,"简账恢复-"+state.id),hash)) throw new Exception("Failed first installation lost a late personal export.");passed++;
    }
    public static int Main(string[] args) {
      if(args.Length==3&&args[0]=="--rollback-child") {
        InitializeRollback(Path.GetFullPath(args[1]));
        Set("fileTestFault",new Action<string>(delegate(string point) {if(point==args[2]) Environment.Exit(99);}));
        CompleteFileRollback(); return 3;
      }
      if(args.Length==3&&args[0]=="--uninstall-child") {
        InitializeUninstall(Path.GetFullPath(args[1]));
        Set("fileTestFault",new Action<string>(delegate(string point) { if(point==args[2]) Environment.Exit(99); }));
        if(args[2]=="uninstall.beforePublish") Invoke("BeginUninstall"); else Invoke("FinishUninstall");
        return 3;
      }
      if(args.Length==3&&args[0]=="--publish-child") {
        Setup(Path.GetFullPath(args[1]),"Preparing");
        Set("fileTestFault",new Action<string>(delegate(string point) { if(point==args[2]) Environment.Exit(99); }));
        Invoke("PublishInitialJournal"); return 3;
      }
      bool journalOnly=args.Length==2&&args[0]=="--journal-publication-tests";
      bool diagnosticsOnly=args.Length==2&&args[0]=="--journal-diagnostics-tests";
      if(args.Length!=1&&!journalOnly&&!diagnosticsOnly) return 2;
      string root=Path.GetFullPath(args[journalOnly||diagnosticsOnly?1:0]); Directory.CreateDirectory(root);
      try {
        if(diagnosticsOnly){
#if INSTALLER_QA
          JournalDiagnostic(Path.Combine(root,"normal"),false);JournalDiagnostic(Path.Combine(root,"blocked"),true);
          Console.WriteLine("JOURNAL_DIAGNOSTIC_TESTS passed="+passed+" registry_access=none");return 0;
#else
          throw new Exception("Diagnostic tests require the existing INSTALLER_QA and INSTALLER_FILE_TESTS definitions.");
#endif
        }
        if(journalOnly){JournalPublicationCases(root,true);Console.WriteLine("JOURNAL_PUBLICATION_TESTS passed="+passed+" registry_access=none");return 0;}
        Invoke("Probe",root);
        if(Directory.GetFileSystemEntries(root).Length!=0) throw new Exception("Probe left a file behind.");
        passed++;
        Reject(delegate { Invoke("Under",root,"../outside.txt"); },"path traversal");
        Reject(delegate { Invoke("Under",root,"C:\\outside.txt"); },"absolute path");
        string file=Path.Combine(root,"existing.txt"); File.WriteAllText(file,"stable",Encoding.UTF8);
        string before=File.ReadAllText(file);
        using((SafeHandle)Invoke("LockFile",file)) {}
        if(File.ReadAllText(file)!=before) throw new Exception("Lock probe changed contents.");
        passed++;
        using(var locked=new FileStream(file,FileMode.Open,FileAccess.ReadWrite,FileShare.None)) {
          Reject(delegate { using((SafeHandle)Invoke("LockFile",file)) {} },"locked file");
        }
        File.SetAttributes(file,FileAttributes.ReadOnly);
        try { Reject(delegate { using((SafeHandle)Invoke("LockFile",file)) {} },"read-only file"); }
        finally { File.SetAttributes(file,FileAttributes.Normal); }
        string conflict=Path.Combine(root,"data"); File.WriteAllText(conflict,"file, not directory");
        Reject(delegate { Invoke("CheckAncestors",Path.Combine(conflict,"nested")); },"parent is file");
        string sha=(string)Invoke("Hash",file);
        var expected=new[]{new PayloadFile {path="existing.txt",bytes=new FileInfo(file).Length,sha256=sha},new PayloadFile {path="data",bytes=new FileInfo(conflict).Length,sha256=(string)Invoke("Hash",conflict)}};
        Invoke("CheckFiles",root,expected,true); passed++;
        File.AppendAllText(file,"tamper");
        Reject(delegate { Invoke("CheckFiles",root,expected,true); },"payload tamper");
        foreach(string boundary in new[]{"journal.beforeCreate","journal.beforeWrite","journal.beforeFlush","publish.beforeMove"}) PublishFailure(Path.Combine(root,boundary.Replace('.','-')),boundary);
        foreach(string boundary in new[]{"journal.beforeFlush","publish.beforeMove"}) PublishCrash(Path.Combine(root,"crash-"+boundary.Replace('.','-')),boundary);
        foreach(string phase in new[]{"RolledBack","Committed"}) CleanupLocked(Path.Combine(root,"cleanup-lock-"+phase),phase);
        foreach(string boundary in new[]{"cleanup.beforeMove","cleanup.beforeJournalDelete","cleanup.afterJournalDelete"}) CleanupFailure(Path.Combine(root,boundary.Replace('.','-')),boundary);
        var unknown=Setup(Path.Combine(root,"unknown-terminal"),"RolledBack");
        string unknownRoot=unknown.install+".__jianzhang_transaction.cleanup-"+unknown.id; Directory.CreateDirectory(unknownRoot);
        File.WriteAllText(Path.Combine(unknownRoot,"foreign.txt"),"preserve");
        Reject(delegate { Invoke("CleanupTerminalDirectories"); },"unexpected terminal contents");
        if(!File.Exists(Path.Combine(unknownRoot,"foreign.txt"))) throw new Exception("Unexpected terminal file was removed.");
        SuccessfulUpgrades(Path.Combine(root,"成功升级 中文 空格"));
        PreservationRejected(Path.Combine(root,"file-collision"),"data/notes.json",false);
        PreservationRejected(Path.Combine(root,"case-file-collision"),"data/NOTES.JSON",false);
        PreservationRejected(Path.Combine(root,"folder-collision"),"我的备份 空格",false);
        PreservationRejected(Path.Combine(root,"empty-folder-collision"),"空目录 保留",false);
        PreservationRejected(Path.Combine(root,"modified-owned-collision"),null,true);
        PreservationLock(Path.Combine(root,"personal-file-lock"),false);
        PreservationLock(Path.Combine(root,"copy-failure"),true);
        OwnershipRejected(Path.Combine(root,"legacy-no-manifest"),false);
        OwnershipRejected(Path.Combine(root,"tampered-manifest"),true);
        ModifiedUninstallRejected(Path.Combine(root,"modified-uninstall"));
        LegacyBackupRejected(Path.Combine(root,"legacy-backup"));
        ModifiedObsoletePreserved(Path.Combine(root,"modified-obsolete"));
        foreach(string mode in new[]{"edit","add","delete","relock","move-lock"}) RaceRecovery(Path.Combine(root,"race-"+mode),mode);
        foreach(string boundary in new[]{"uninstall.beforeDelete..jianzhang-payload.json","uninstall.afterDelete..jianzhang-payload.json","uninstall.beforeDelete..jianzhang-install-id","uninstall.afterDelete..jianzhang-install-id","uninstall.beforeDeleteEntry"}) UninstallRetry(Path.Combine(root,boundary.Replace('.','-')),boundary,false);
        foreach(string name in new[]{".jianzhang-payload.json",".jianzhang-install-id","Uninstall.exe"}) UninstallRetry(Path.Combine(root,"uninstall-lock-"+name),name,true);
        UninstallMissingRejected(Path.Combine(root,"uninstall-missing-without-record"));
        UninstallLateFailure(Path.Combine(root,"uninstall-late-failure"));
        foreach(string boundary in new[]{"uninstall.beforePublish","uninstall.afterDelete..jianzhang-install-id","uninstall.beforeDeleteEntry"}) UninstallCrash(Path.Combine(root,"crash-"+boundary.Replace('.','-')),boundary);
        UninstallPartialRetry(Path.Combine(root,"uninstall-partial-payload"));
        UninstallChangedOwned(Path.Combine(root,"uninstall-changed-after-begin"));
        foreach(string mode in new[]{"edit","conflict","unchanged","modified-managed"}) LateRollback(Path.Combine(root,"late-"+mode),mode);
        foreach(string boundary in new[]{"rollback.afterMoveCandidate","rollback.afterPersonalCopy","rollback.afterPersonalMerge","rollback.afterRestoreOld","rollback.beforeCandidateDelete","rollback.afterCandidateRetire"}) LateRollbackFailure(Path.Combine(root,boundary.Replace('.','-')),boundary,false);
        foreach(string boundary in new[]{"rollback.afterMoveCandidate","rollback.afterPersonalCopy","rollback.afterRestoreOld","rollback.afterCandidateRetire"}) LateRollbackFailure(Path.Combine(root,"crash-"+boundary.Replace('.','-')),boundary,true);
        LateRollbackLock(Path.Combine(root,"late-personal-lock"));
        FailedFirstInstallPersonal(Path.Combine(root,"first-install-late-personal"));
        AtomicDeleteObject(Path.Combine(root,"atomic-object-delete"));
        foreach(string name in new[]{"data/notes.json","README.txt"}) AtomicRollbackRetry(Path.Combine(root,"atomic-rollback-"+name.Replace('/','-')),name,false);
        foreach(string name in new[]{".jianzhang-payload.json",".jianzhang-install-id"}) AtomicRollbackRetry(Path.Combine(root,"atomic-rollback-identity-"+name),name,true);
        foreach(string name in new[]{"README.txt",".jianzhang-payload.json",".jianzhang-install-id","Uninstall.exe"}) AtomicUninstallRetry(Path.Combine(root,"atomic-uninstall-"+name),name);
        BudgetReviewerInput(Path.Combine(root,"budget-long"),false);
        BudgetReviewerInput(Path.Combine(root,"budget-marker"),true);
        foreach(string kind in new[]{"manifest","personal","directory"}) BudgetRelativeInput(Path.Combine(root,"budget-"+kind),kind);
        BudgetBoundaryTransaction(Path.Combine(root,"budget-boundary"));
        JournalPublicationCases(Path.Combine(root,"journal-replace"),false);
        Console.WriteLine("FILE_ONLY_TESTS passed="+passed+" registry_access=none");
        return 0;
      } catch(Exception error) {
        Console.Error.WriteLine(error);
        for(Exception detail=error;detail!=null;detail=detail.InnerException) Console.Error.WriteLine("FILE_TEST_ERROR type="+detail.GetType().FullName+" hresult=0x"+detail.HResult.ToString("X8")+(detail is System.ComponentModel.Win32Exception?" win32="+((System.ComponentModel.Win32Exception)detail).NativeErrorCode:""));
        return 1;
      }
    }
  }
}
