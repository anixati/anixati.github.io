using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Linq;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace Ko.NBlink
{
    internal interface ISocketService
    {
    }
    internal class BlinkWsService : ISocketService,
        IMessageHandler<ConnectCmd>,
        IMessageHandler<CleanUpCmd>,
        IMessageHandler<CdpRequest>
    {
        private const int TimeOut = 1500;
        private const int ChunkSize = 1024;
        private Uri _cwsUrl = null;
        private readonly ClientWebSocket _cws;
        private readonly ICmdDispatcher _dispatcher;
        private readonly BlockingCollection<CdpRequest> _sendQueue = new BlockingCollection<CdpRequest>(1000);
        private readonly BlockingCollection<CdpResponse> _recvQueue = new BlockingCollection<CdpResponse>(1000);
        private bool _isReceiverRunning = false;
        private bool _isSenderRunning = false;
        public BlinkWsService(ICmdDispatcher dispatcher)
        {
            _dispatcher = dispatcher;
            _cws = new ClientWebSocket { Options = { KeepAliveInterval = new TimeSpan(1, 0, 0) } };
            StartRouter();
        }
        public WebSocketState State => _cws.State;
        private void StartSender(CancellationToken token)
        {
            Task.Run(async () =>
            {
                await Task.Delay(1);
                foreach (var request in _sendQueue.GetConsumingEnumerable())
                {
                    try
                    {
                        var data = request.AsSerialized();
                        Console.WriteLine(data);
                        var bytes = Encoding.UTF8.GetBytes(data);
                        var sendBuffer = new ArraySegment<byte>(bytes);
                        await _cws.SendAsync(sendBuffer, WebSocketMessageType.Text, true, token);
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"Send Error  {ex}");
                    }
                }

            });
        }

        private void StartReceiver(CancellationToken token)
        {
            var reqReconnect = false;
            Task.Run(async () =>
            {
                _isReceiverRunning = true;
                while (_cws.State == WebSocketState.Open)
                {
                    try
                    {
                        var rcvMsg = string.Empty;
                        ReadChunk:
                        var buffer = new byte[ChunkSize];
                        var rcvBuffer = new ArraySegment<byte>(buffer);
                        var result = await _cws.ReceiveAsync(rcvBuffer, token);
                        if (result.MessageType == WebSocketMessageType.Close)
                        {
                            Console.WriteLine("Closing ws msg received!");
                            await _cws.CloseAsync(WebSocketCloseStatus.NormalClosure, string.Empty, token);
                            break;
                        }
                        else
                        {
                            var recBytes = rcvBuffer.Skip(rcvBuffer.Offset).Take(result.Count).ToArray();

                            if (!result.EndOfMessage)
                            {
                                rcvMsg += Encoding.UTF8.GetString(recBytes).TrimEnd('\0');
                                goto ReadChunk;
                            }

                            rcvMsg += Encoding.UTF8.GetString(recBytes).TrimEnd('\0');
                        }
                        try
                        {
                            Console.ForegroundColor = ConsoleColor.Cyan;
                            Console.WriteLine(rcvMsg);
                            Console.ForegroundColor = ConsoleColor.White;


                            _recvQueue.Add(new CdpResponse(rcvMsg));
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine(ex);
                            Console.WriteLine(rcvMsg);
                        }
                    }
                    catch (WebSocketException wex)
                    {
                        Console.WriteLine($" Ws {wex} Error");
                        if (wex.WebSocketErrorCode == WebSocketError.ConnectionClosedPrematurely)
                        {
                            reqReconnect = true;
                        }
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"receive Error  {ex}");
                    }
                }
                _isReceiverRunning = false;
                Console.WriteLine("Read loop exit");
                if (reqReconnect)

                    await Task.Delay(1);
            });
        }

        private void DisConnect(CancellationToken token)
        {
            try
            {
                if (_cws.State == WebSocketState.Open)
                    _cws.CloseAsync(WebSocketCloseStatus.NormalClosure, "Closing", token)
                           .Wait(100);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to disconnect {ex}");
            }
        }

        public async Task Send(CdpRequest message)
        {
            await Task.Run(() =>
            {
                message.Finalise();
                _sendQueue.Add(message);
            });
        }

        private async Task StartConnect(CancellationToken token)
        {
            if (_cws == null)
                return;
            if (_cws.State != WebSocketState.Open)
            {
                await _cws.ConnectAsync(_cwsUrl, token);

                Task.Run(async () =>
                {
                    while (_cws.State != WebSocketState.Open)
                        await Task.Delay(1);
                }).Wait(15000);
            }
            if (!_isSenderRunning)
                StartSender(token);
            if (!_isReceiverRunning)
                StartReceiver(token);
            // Consele.WriteLine($"Connected to cdtp ws @ {_cwsUrl}");

        }
        private void StartRouter()
        {
            Task.Run(async () =>
            {
                await Task.Delay(1);
                foreach (var request in _recvQueue.GetConsumingEnumerable())
                    HandleCdpResponse(_dispatcher,request);
            });
        }
        private static void HandleCdpResponse(ICmdDispatcher service,CdpResponse request)
        {
            if (request.IsMsgTargetPageCreated())
            {
                Browser.Context.TargetId = request.GetValue("params.targetInfo.targetId");
                Console.WriteLine(Browser.Context);
                service.Publish(CdpApi.GetOpenSessionMsg());
                return;
            }
            if (request.IsMsgSessionCreated())
            {
                Browser.Context.SessionId = request.GetValue("params.targetInfo.targetId");
                Console.WriteLine(Browser.Context);
                return;
            }
        }
        public async Task Execute(CleanUpCmd message, CancellationToken token)
        {
            Console.WriteLine("Cleaning up browser process ...");
            await Task.Delay(1);
            _sendQueue.CompleteAdding();
            DisConnect(token);
        }
        public async Task Execute(ConnectCmd message, CancellationToken token)
        {
            _cwsUrl = message.WsUrl;
            await StartConnect(token);
            await Send(CdpApi.GetDiscoverTargetsMsg());
        }
        public async Task Execute(CdpRequest message, CancellationToken token)
        {
            await Send(message);
        }
    }
    public sealed class Browser
    {
        private static readonly Lazy<Browser> _blink =
            new Lazy<Browser>(() => new Browser());
        private int _methodId;
        private readonly ConcurrentDictionary<int, Action<object>> _callbacks;

        private Browser()
        {
            _methodId = 2;
            _callbacks = new ConcurrentDictionary<int, Action<object>>();
        }
        public int Id => _methodId;
        public string TargetId { get; set; }
        public string SessionId { get; set; }
        public void Prepare(Action<object> cbk)
        {
            Interlocked.Add(ref _methodId, 1);
        }
        public static Browser Context { get { return _blink.Value; } }
        public override string ToString()
        {
            return $"t: {TargetId} s: {SessionId}";
        }
    }
    public abstract class CdpMessage
    {
        [JsonProperty(PropertyName = "id", Order = -5)]
        public abstract int Id { get;  }
        [JsonProperty(PropertyName = "method", Order = -4)]
        public abstract string Method { get;  }
    }
    public abstract class CdpRequest: CdpMessage,IProcessCmd
    {
        private readonly int _id;
        private readonly string _method;
        public CdpRequest(string method, int id = 0) 
        {
            _method = method;
            _id = id;
        }
        public override int Id => _id;
        public override string Method => _method;
        [JsonProperty("params")]
        public object Data { get; set; }
        public abstract void Finalise();
    }
    public class CdpResponse : CdpMessage
    {
        private readonly JObject _job;
        public override int Id => _id;
        public override string Method => _method;
        private readonly int _id;
        private readonly string _method;
        public CdpResponse(string payload)
        {
            if (!string.IsNullOrEmpty(payload))
            {
                _job = JObject.Parse(payload);
                if (HasKey(CdpApi.Id))
                    _id = int.Parse(GetValue(CdpApi.Id));
                if (HasKey(CdpApi.Method))
                    _method = GetValue(CdpApi.Method);
            }
        }
        public bool HasKey(string key){return _job.ContainsKey("key");}
        public string GetValue(string key){return _job.SelectToken(key)?.ToString();}
        public bool IsMethod(string key){return string.Compare(key, Method, true) == 0;}
    }
    public class GenericRequest : CdpRequest{
        private readonly Dictionary<string, object> _data;
        public GenericRequest(string method, int id = 0) : base(method, id){
            _data = new Dictionary<string, object>();}
public GenericRequest Add(string key, object value)
        {
            _data[key.ToLower()] = value;
            return this;
        }
        public override void Finalise()
        {
            Data = _data;
        }
    }
    public static class CdpApi
    {
        public const string Id = "id";
        public const string Method = "method";
        public const string SessionId = "sessionId";
        public class Methods
        {
            public const string DiscoverTargets = "Target.setDiscoverTargets";
            public const string TargetCreated = "Target.targetCreated";
            public const string TargetAttach = "Target.attachToTarget";
            public const string TargetDestroyed = "Target.targetDestroyed";
            public const string TargetSendMsg = "Target.sendMessageToTarget";
            public const string TargetRecvMsg = "Target.receivedMessageFromTarget";
            public const string RuntimeEval = "Runtime.evaluate";
            public const string RuntimeAddBind = "Runtime.addBinding";
            public const string RuntimeBindCalled = "Runtime.bindingCalled";
            public const string RuntimeConsoleApi = "Runtime.consoleAPICalled";
            public const string RuntimeException = "Runtime.exceptionThrown";
            public const string PageNavigate = "Page.navigate";
            public const string PageAddScript = "Page.addScriptToEvaluateOnNewDocument";
            public const string BrowserGetWinTarget = "Browser.getWindowForTarget";
            public const string BrowserGetWinBounds = "Browser.setWindowBounds";
            public const string BrowserSetWinBounds = "Browser.getWindowBounds";
        }
        public static readonly StringDictionary Configure = new StringDictionary
        {{"Page.enable","" },{"Target.setAutoAttach","{\"autoAttach\":true,\"waitForDebuggerOnStart\": false}" },{"Network.enable","" },{"Runtime.enable","" },{"Security.enable","" },{"Performance.enable","" },{"Log.enable","" }
        };
        public static CdpRequest GetDiscoverTargetsMsg()
        {return new GenericRequest(Methods.DiscoverTargets, 0).Add("discover", true);}
        public static CdpRequest GetOpenSessionMsg()
        {
            return new GenericRequest(Methods.DiscoverTargets, 0).Add("targetId", Browser.Context.TargetId);
        }
        public static string AsSerialized(this CdpRequest request)
        {
            request.Finalise();
            return JsonConvert.SerializeObject(request);
        }
        public static bool HasKeyValue(this CdpResponse response,string key, string value)
        {
            return string.Compare(response.GetValue(key), value , true) == 0;
        }
        public static bool IsMsgTargetPageCreated(this CdpResponse response)
        {
            return response.IsMethod(Methods.TargetCreated) &&
                response.HasKeyValue("params.targetInfo.type", "page");
        }
        public static bool IsMsgSessionCreated(this CdpResponse response)
        {
            return response.HasKey(CdpApi.SessionId) && response.Id == 1;
        }
    }
}
