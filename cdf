_________________________________________________
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Ko.NBlink
{
    public interface IBrowser
    {
    }
    public class StartCmd : IProcessCmd
    {
    }
    public class CleanUpCmd : IProcessCmd
    {
    }
    public abstract class BrowserBase: IBrowser
    {
        private bool _isRunning;
        static readonly Regex dtregex = new Regex(@"^DevTools listening on (ws://.*)$");
        static readonly AutoResetEvent _cdpStart = new AutoResetEvent(false);
        public string WsUrl { get; private set; }
        Process _process;

        protected  ICmdDispatcher Dispatcher;
        public BrowserBase(ICmdDispatcher dispatcher)
        {
            Dispatcher = dispatcher;
            _isRunning = false;
        }

        protected void Start(CancellationToken token)
        {
            if (_isRunning || token.IsCancellationRequested) Stop();
            var stdout = new StringBuilder();
            _process = new Process
            {
                StartInfo = GetProcessInfo()
            };
            _process.StartInfo.UseShellExecute = false;
            _process.StartInfo.RedirectStandardOutput = true;
            _process.StartInfo.RedirectStandardError = true;
            _process.OutputDataReceived += (sender, ed) =>
            {
                Log(ed.Data);
            };
            _process.ErrorDataReceived += (sender, ed) =>
            {
                //^DevTools listening on (ws://.*)\n$
                if (!string.IsNullOrEmpty(ed.Data))
                {
                    Log(ed.Data);
                    var results = dtregex.Matches(ed.Data);
                    if (results.Count > 0)
                    {
                        WsUrl = results.First().Groups[1].Value;
                        Log(WsUrl);
                        _cdpStart.Set();
                    }
                }
                stdout.Append(ed.Data);
            };
            try
            {
                var sflag = _process.Start();
                if (!sflag)
                    throw new Exception("Failed to start the process");
                _process.BeginOutputReadLine();
                _process.BeginErrorReadLine();

                if (_cdpStart.WaitOne(new TimeSpan(0, 0, 10)))
                {
                    _isRunning = true;
                    _process.WaitForExit();
                    Dispatcher.Publish(new CleanUpCmd());
                }
                else
                {
                    Log("timed out");
                    Stop();
                    throw new Exception("Timed out waiting for CDP");
                }
            }
           finally
            {
                _process.CancelOutputRead();
                _process.CancelErrorRead();
            }
        }


        protected void Stop()
        {
            if (_process != null)
            {
                if (!_process.HasExited)
                    _process.Kill();
                _process.Dispose();
                _process = null;
                _isRunning = false;
            }
            Dispatcher.ExitApp();
        }
        private void Log(string msg)
        {
            Console.WriteLine(msg);
        }

        private ProcessStartInfo GetProcessInfo()
        {
            var args = new HashSet<string>
            {
                "--output",
                "--disable-background-mode",
                "--disable-plugins",
                "--disable-plugins-discovery",
                "--disable-background-networking",
                "--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-breakpad",
                "--disable-client-side-phishing-detection",
                "--disable-default-apps",
                "--disable-dev-shm-usage",
                "--disable-infobars",
                "--disable-extensions",
                "--disable-features=site-per-process",
                "--disable-hang-monitor",
                "--disable-ipc-flooding-protection",
                "--disable-popup-blocking",
                "--disable-prompt-on-repost",
                "--disable-renderer-backgrounding",
                "--disable-sync",
                "--disable-translate",
                "--metrics-recording-only",
                "--no-experiments",
                "--no-pings",
                "--no-first-run",
                "--safebrowsing-disable-auto-update",
                "--enable-automation",
                "--password-store=basic",
                "--use-mock-keychain",
                "--window-size=500,500",
                "--remote-debugging-port=0",
                $"--app=\"{GetAppPath()}\"",
                $"--user-data-dir={GetUserDirectory()}"
            };
            foreach (var x in GetUserArgs())
                args.Add(x);
            return new ProcessStartInfo(GetBrowserPath(), string.Join(" ", args.ToArray()));
        }
        protected virtual List<string> GetUserArgs()
        {
            return new List<string>();
        }
        protected abstract string GetBrowserPath();
        protected abstract string GetUserDirectory();
        protected abstract string GetAppPath();
    }

    public class WinBrowser : BrowserBase, IMessageHandler<StartCmd>, IMessageHandler<CleanUpCmd>
    {
        public WinBrowser(ICmdDispatcher dispatcher):base(dispatcher)
        {
        }
        public async Task Execute(StartCmd message, CancellationToken token)
        {
            await Task.Delay(1);
            Start(token);
        }

        public async Task Execute(CleanUpCmd message, CancellationToken token)
        {
            await Task.Delay(1);
            Stop();

        }

        protected override string GetAppPath()
        {
            return "data:text/html,<html><body></body></html>";
        }

        protected override string GetBrowserPath()
        {
            return "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe";
        }

        protected override string GetUserDirectory()
        {
            var rval = Path.GetFullPath(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")));
            Directory.CreateDirectory(rval);
            return rval;
        }
    }

}

_________________________________________________
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Threading.Tasks.Dataflow;

namespace Ko.NBlink
{
    public interface IProcessCmd
    {
    }
    public interface ICmdDispatcher
    {
        void ExitApp();
        Task Publish<T>(T message) where T : IProcessCmd, new();

        Task Publish<T>(T message, CancellationToken token) where T : IProcessCmd, new();
    }

    public interface IMessageHandler<T> where T : IProcessCmd, new()
    {
        Task Execute(T message, CancellationToken token);
    }

    public class TaskState
    {
        public bool Completed { get { return ErrorMsgs.Count > 0; } }
        public List<string> ErrorMsgs { get; set; } = new List<string>();

        public void AddException(Exception ex)
        {
            ErrorMsgs.Add(ex.Message);
        }
    }

    internal sealed class HandlerRequest
    {
        public object Message { get; private set; }
        public CancellationToken CancelToken { get; private set; }
        public Action<TaskState> OnComplete { get; private set; }

        public HandlerRequest(object message, CancellationToken token, Action<TaskState> onComplete)
        {
            Message = message;
            CancelToken = token;
            OnComplete = onComplete;
        }

    }

    internal sealed class CmdDispatcher: ICmdDispatcher
    {
        private readonly ActionBlock<HandlerRequest> _actionQueue;
        private readonly ConcurrentQueue<Func<object, CancellationToken, Task>> _cmdHandlers;

        public CmdDispatcher()
        {
            _cmdHandlers = new ConcurrentQueue<Func<object, CancellationToken, Task>>();
            var handlers = new List<Func<object, CancellationToken, Task>>();
            _actionQueue = new ActionBlock<HandlerRequest>(async rq =>
            {
                while (_cmdHandlers.TryDequeue(out Func<object, CancellationToken, Task> newHandler))
                    handlers.Add(newHandler);

                var result = new TaskState();
                foreach (var handler in handlers)
                {
                    if (rq.CancelToken.IsCancellationRequested)
                    {
                        break;
                    }
                    try
                    {
                        await handler.Invoke(rq.Message, rq.CancelToken);
                    }
                    catch (Exception ex)
                    {
                        result.AddException(ex);
                        continue;
                    }
                }
                rq.OnComplete(result);
            }, new ExecutionDataflowBlockOptions { BoundedCapacity = 1000, MaxDegreeOfParallelism = Environment.ProcessorCount });
        }
        public AutoResetEvent AppExit { get; } = new AutoResetEvent(false);

        public void Register<T>(IMessageHandler<T> cmdHandler) where T : IProcessCmd, new()
        {
            async Task handler(object m, CancellationToken token)
            {
                if (m.GetType() == typeof(T))
                    await cmdHandler.Execute((T)m, token);
            }
            _cmdHandlers.Enqueue(handler);
        }


        public Task Publish<T>(T message) where T : IProcessCmd, new()
        {
            return Publish(message, CancellationToken.None);
        }

        public Task Publish<T>(T message, CancellationToken token) where T : IProcessCmd, new()
        {
            var tcs = new TaskCompletionSource<TaskState>();
            _actionQueue.Post(new HandlerRequest(message, token, result => tcs.SetResult(result)));
            return tcs.Task;
        }
        public void ExitApp()
        {
            AppExit.Set();
        }
    }




    }


_________________________________________________
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Ko.NBlink
{



    public sealed class BootStrapper
    {
        private BootStrapper()
        {
        }

        public static void Start()
        {

            var config = new NBlinkConfig();
            var blink = new NBlink(config);

            blink.Setup();
            blink.Execute();
        }

    }




    internal sealed class NBlink 
    {
        private readonly NBlinkConfig _config;
        private readonly CmdDispatcher _dispatcher;
        public NBlink(NBlinkConfig config):base()
        {
            _config = config;
            _dispatcher = new CmdDispatcher();
        }

        public void Execute()
        {
            _dispatcher.Publish(new StartCmd());
            _dispatcher.AppExit.WaitOne();
            Console.WriteLine("...");
        }
        public void Setup()
        {
            var wbr = new WinBrowser(_dispatcher);
            _dispatcher.Register<StartCmd>(wbr);
            _dispatcher.Register<CleanUpCmd>(wbr);


        }
        private void LoadPlatformInfo()
        {
        }
    }
    public class NBlinkConfig
    {
    }
}
_________________________________________________
 static void Main(string[] args)
        {
            Console.WriteLine($"Running as {Environment.UserDomainName}\\{Environment.UserName}");

            LocalServer.Start();
            // BootStrapper.Start();
            Console.WriteLine("Exited");
            Console.Read();
        }
_________________________________________________
    public class LocalServer
    {
        public static void Start()
        {

            if (!HttpListener.IsSupported)
            {
                Console.WriteLine("Windows XP SP2 or Server 2003 is required to use the HttpListener class.");
                return;
            }
            var tcpl = new TcpListener(IPAddress.Loopback, 0);
            tcpl.Start();
            int port = ((IPEndPoint)tcpl.LocalEndpoint).Port;
            tcpl.Stop();

            Console.WriteLine(port);
        }
    }
_________________________________________________using Ko.Common;
using System;
using System.Collections.Generic;

namespace Ko.AdShed.Domain
{
    #region User Management
    public enum AppRole
    {
        User,
        Agent,
        System
    }
    public class AppUser : EntityBase
    {
        public string UserName { get; set; }
        public AppRole AppRole { get; set; }

        public string FirstName { get; set; }
        public string MiddleName { get; set; }
        public string LastName { get; set; }
    }
    public class UserProfile : EntityBase
    {
        public int AppUserId { get; set; }
        public AppUser AppUser { get; set; }
        public string Email1 { get; set; }
        public string Email2 { get; set; }
        public string Phone1 { get; set; }
        public string Phone2 { get; set; }
        public string Mobile { get; set; }
        public bool EmailVerified { get; set; }
        public bool MobileVerified { get; set; }
    }
    public class UserAddress : EntityBase
    {
        public int AppUserId { get; set; }
        public AppUser AppUser { get; set; }
        public string Street1 { get; set; }
        public string Street2 { get; set; }
        public string City { get; set; }
        public string State { get; set; }
        public string Country { get; set; }

    }
    public class UserLog : EntityBase
    {
        public int AppUserId { get; set; }
        public AppUser AppUser { get; set; }
        public string ClientIp { get; set; }
        public string Latitude { get; set; }
        public string Longitude { get; set; }
    }
    #endregion

    #region Membership

    public class MembershipType : EntityBase
    {
        public string Code { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public int Level { get; set; }
        public bool IsPaid { get; set; }
        public bool IsTrial { get; set; }
        public int TrialDays { get; set; }
        public int AllowedDays { get; set; }
    }
    public class AppFeature : EntityBase
    {
        public string Code { get; set; }
        public string Name { get; set; }
        public DateTime? Expiry { get; set; }
        public int? Limit { get; set; }
    }

    public class MemberFeature : EntityBase
    {
        public int MembershipTypeId { get; set; }
        public MembershipType MembershipType { get; set; }
        public int AppFeatureId { get; set; }
        public AppFeature AppFeature { get; set; }
    }

    #endregion


    public class Location : EntityBase
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public bool IsRoot { get; set; }
    }

    public class LocationMap : EntityBase
    {
        public int? ParentId { get; set; }
        public Location Parent { get; set; }

        public int? ChildId { get; set; }
        public Location Child { get; set; }
    }



    public class Category : EntityBase
    {
        public string Code { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public bool IsRoot { get; set; }
        public bool LocationBased { get; set; }

    }

    public class CategoryMap : EntityBase
    {
        public int ParentId { get; set; }
        public Category Parent { get; set; }

        public int ChildId { get; set; }
        public Category Child { get; set; }
    }


    //Schema
    //SchemaItem
    //SchemaValues
    #region Schema
    public class Schema : EntityBase
    {
        public int CategoryId { get; set; }
        public Category Category { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public DateTime? Expiry { get; set; }
        public int Version { get; set; }
    }
    public enum ItemType
    {
        Text,
        Options,
        Number,
        Date,
        Range,
        Custom
    }

    public enum ItemSubType
    {
        Dimention,

    }

    public class SchemaItem : EntityBase
    {
        public int SchemaId { get; set; }
        public Schema Schema { get; set; }
        public string Label { get; set; }
        public ItemType ItemType { get; set; }
        public ItemType SubType { get; set; }
        public string Units { get; set; }

        public ICollection<SchemaItemValue> ItemValues { get; set; }
    }

    public class SchemaItemValue : EntityBase
    {
        public int SchemaItemId { get; set; }
        public SchemaItem SchemaItem { get; set; }
        public string Text { get; set; }
        public int? Value { get; set; }
    }

    #endregion
    
    public enum ResourceType
    {
        Image,
        Attachment
    }
    public class MediaItem : EntityBase
    {
        public string Name { get; set; }
        public string Value { get; set; }
        public string Path { get; set; }
        public Guid ResourceId { get; set; }
        public ResourceType ResourceType { get; set; }
        public string MediaType { get; set; }
    }

    public class AdItem : EntityBase
    {
        public int AppUserId { get; set; }
        public AppUser AppUser { get; set; }

        public int CategoryId { get; set; }
        public Category Category { get; set; }

        public int LocationId { get; set; }
        public Location Location { get; set; }

        public DateTime? ExpiryDate { get; set; }

        public string Title { get; set; }
        public string Description { get; set; }
        public string Attributes { get; set; }
    }
    public class AdMedia : EntityBase
    {
        public int AdItemId { get; set; }
        public AdItem AdItem { get; set; }
        public int MediaItemId { get; set; }
        public MediaItem MediaItem { get; set; }
    }
    public enum ResponseType
    {
        Comment,
        Review,
        Enquiry,
        Submission
    }
    public class AdResponse : EntityBase
    {
        public int AppUserId { get; set; }
        public AppUser AppUser { get; set; }
        public int AdItemId { get; set; }
        public AdItem AdItem { get; set; }
        public string Response { get; set; }
    }

    public class AdResponseMedia : EntityBase
    {
        public int AdResponseId { get; set; }
        public AdResponse AdResponse { get; set; }
        public int MediaItemId { get; set; }
        public MediaItem MediaItem { get; set; }
    }
}
