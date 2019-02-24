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
    }
	
	----
	
	using Ko.NBlink.Core;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Ko.NBlink.Services
{
    internal interface ISocketService
    {

    }
    internal class BlinkWsService : DisposableBase,ISocketService, IBlinkEventHandler<ConnectCmd>, IBlinkEventHandler<CleanUpCmd>
    {
        private const int TimeOut = 1500;
        private const int ChunkSize = 1024;
        private Uri _cwsUrl = null;
        private readonly ClientWebSocket _cws;
        private readonly IBlinkDispatcher _dispatcher;
        private readonly ILogger _logger;
        private readonly BlockingCollection<CdtReqMessage> _sendQueue = new BlockingCollection<CdtReqMessage>(1000);
        private readonly BlockingCollection<CdtRespMessage> _recvQueue = new BlockingCollection<CdtRespMessage>(1000);
        private bool _isReceiverRunning = false;
        private bool _isSenderRunning = false;
        public BlinkWsService(ILoggerFactory loggerFactory,  IBlinkDispatcher dispatcher)
        {
            _logger = loggerFactory.CreateLogger(this.GetType().Name);
            _dispatcher = dispatcher;
            _cws= new ClientWebSocket{ Options = { KeepAliveInterval = new TimeSpan(1,0,0) } };
            StartRouter();
        }

        #region Connectivity

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
                        var bytes = Encoding.UTF8.GetBytes(request.PayLoad);
                        var sendBuffer = new ArraySegment<byte>(bytes);
                        await _cws.SendAsync(sendBuffer, WebSocketMessageType.Text, true, token);
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Send Error");
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
                            _logger.LogWarning("Closing ws msg received!");
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

                        _logger.LogInformation(rcvMsg);
                        _recvQueue.Add(new CdtRespMessage {PayLoad = rcvMsg});
                    }
                    catch (WebSocketException wex)
                    {
                        _logger.LogError(wex, "WS Error");
                        if (wex.WebSocketErrorCode == WebSocketError.ConnectionClosedPrematurely)
                        {
                            reqReconnect = true;
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Receive Error");
                    }
                }
                _isReceiverRunning = false;
                _logger.LogWarning("Read loop exit");
                if(reqReconnect)

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
                _logger.LogError(ex, "Failed to disconnect");
            }
        }

        protected override void DisposeLocal()
        {
            if (_cws != null)
            {
                if (_cws.State == WebSocketState.Open)
                    DisConnect(CancellationToken.None);
                _cws.Dispose();
            }
        }
        
        private void Send(CdtReqMessage message)
        {
            Task.Run(() =>
            {
                _logger.LogInformation($"sending >> {message.PayLoad}");
                _sendQueue.Add(message);
            }).Wait();
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
          //  _logger.LogInformation($"Connected to cdtp ws @ {_cwsUrl}");

        }
        private void StartRouter()
        {
            Task.Run(async () =>
            {
                await Task.Delay(1);
                foreach (var request in _recvQueue.GetConsumingEnumerable())
                {
                    try
                    {
                        if (request.HasKeyValue("method", "Target.targetCreated") &&
                            request.HasKeyValue("params.targetInfo.type", "page"))
                        {
                            Browser.Context.TargetId = request.GetValue("params.targetInfo.targetId");
                            _logger.LogInformation("target id " + Browser.Context.TargetId);
                            Send(CdtMsgBuilder.OpenSession());
                        }

                        if (request.HasKey("sessionId") && request.HasKeyValue("id", "1"))
                        {
                            Browser.Context.SessionId = request.GetValue("sessionId");
                            _logger.LogInformation("session id " + Browser.Context.SessionId);
                        }

                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Parsing Error");
                    }
                }
            });
        }

        #endregion

        public async Task Execute(CleanUpCmd message, CancellationToken token)
        {
            _logger.LogInformation("Cleaning up browser process ...");
            await Task.Delay(1);
            _sendQueue.CompleteAdding();
            DisConnect(token);
        }
        
        public async Task Execute(ConnectCmd message, CancellationToken token)
        {
            _cwsUrl = message.WsUrl;
            await StartConnect(token);
            Send(CdtMsgBuilder.GetPageTarget());
        }


    }

    
}

public class CdtRespMessage
    {
        public string PayLoad { get; set; }

        public string GetValue(string key)
        {
            var jo = GetObj();
            if (jo != null)
                return jo.SelectToken(key)?.ToString();
            return null;
        }
        public bool HasKey(string key)
        {
            var jo = GetObj();
            if (jo != null)
                return jo.ContainsKey("key");
            return false;
        }

        private JObject _job = null; 
        private JObject GetObj()
        {
            if (_job == null &&  !string.IsNullOrEmpty(PayLoad))
            {
                _job = JObject.Parse(PayLoad);
            }
            return _job;
        }


    }
    
     public class CdtReqMessage
    {
        public string PayLoad { get; set; }
    }


    public static class CdtMsgBuilder
    {

        public static CdtReqMessage GetPageTarget()
        {
            return new CdtReqMessage {PayLoad = "{\"id\": 0, \"method\": \"Target.setDiscoverTargets\", \"params\":{\"discover\": true}}" };
        }

        public static CdtReqMessage OpenSession()
        {
            return new CdtReqMessage { PayLoad = "{\"id\": 1, \"method\": \"Target.attachToTarget\", \"params\":{\"targetId\":\""+ Browser.Context.TargetId + "\"}}" };
        }


        public static CdtReqMessage GetMsg<T>(T obj)where T:class,new()
        {
            var pldStr = JsonConvert.SerializeObject(obj);
            return new CdtReqMessage { PayLoad = pldStr };
        }

    }
----------------------------------------------------------
{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"d2c368c7-e4cb-4a23-88ab-4c2e917e1de1","type":"browser","title":"","url":"","attached":true}}}




    
    
    



