const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '../main/ets');
const logger = { debug() {}, info() {}, error() {} };
function load(file, dependencies) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  const scope = { exports: {}, ArrayBuffer, Uint8Array, Error, Promise, Set, Map, setTimeout, clearTimeout,
    require(name) { assert.ok(name in dependencies, 'Missing dependency: ' + name); return dependencies[name]; } };
  vm.runInNewContext(code, scope, { filename: file });
  return scope.exports;
}
const errors = load('FtpErrors.ets', {});
const parser = load('parser/parseControlResponse.ts', {});
function loadTransfer(Transport) {
  return load('transfer/AbsFtpTransfer.ets', {
    '../FtpLogger': { default: logger }, '../FtpErrors': errors,
    '../socket/FtpSocketTCPImpl': { FtpSocketTCPImpl: Transport },
    '../parser/parseControlResponse': parser, '@kit.BasicServicesKit': { systemDateTime: { getTime: Date.now } }
  }).AbsFtpTransfer;
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
async function tick() { await new Promise(resolve => setImmediate(resolve)); }
async function rejects(promise, pattern) {
  await assert.rejects(promise, error => { assert.match(error.message, pattern); return true; });
}
// 替换服务器与 socket，执行实际 ETS 传输代码；握手与控制响应由用例独立推进。
function fixture(tls = true, timeout = 500) {
  const connected = deferred(), accepted = deferred(), final = deferred();
  const events = [];
  const subscribers = new Set(), closeSubscribers = new Set();
  const socket = {
    _connected: false, closes: 0,
    get connected() { return this._connected; },
    set connected(value) { const wasConnected = this._connected; this._connected = value; if (wasConnected && !value) closeSubscribers.forEach(callback => callback()); },
    subscribeClose(callback) { closeSubscribers.add(callback); return () => closeSubscribers.delete(callback); },
    hasTls() { return tls; },
    connect() { events.push('connect'); return connected.promise.then(() => { socket.connected = true; }); },
    async isConnected() { return socket.connected; },
    subscribeMessage(callback) { subscribers.add(callback); return () => subscribers.delete(callback); },
    async send(bytes) { events.push('data:' + bytes.byteLength); },
    async close() { socket.closes++; socket.connected = false; connected.reject(new Error('socket closed')); },
    emit(bytes) { subscribers.forEach(callback => callback(Uint8Array.from(bytes).buffer)); }
  };
  const transport = tls ? {
    closes: 0,
    async connect() { events.push('tcp-connect'); },
    async close() { transport.closes++; }
  } : socket;
  class Transport { constructor() { return transport; } }
  const AbsFtpTransfer = loadTransfer(Transport);
  const context = {
    timeout, closes: 0, instanceFlag() { return 'fixture'; },
    createSocket(prepared) { assert.equal(prepared, transport); return socket; },
    closeControlConnection() { return context.close(); },
    send(command) { events.push(command); return accepted.promise; },
    consumeNextMessage(value) { assert.equal(value, 0); events.push('listen-final'); return final.promise; },
    async close() { context.closes++; accepted.reject(new Error('context closed')); final.reject(new Error('context closed')); }
  };
  // 服务端尚未发最终响应时关闭也不能产生未处理拒绝。
  final.promise.catch(() => {});
  connected.promise.catch(() => {});
  class Transfer extends AbsFtpTransfer {
    async prepareInternal() { return { address: '127.0.0.1', port: 50000 }; }
  }
  return { socket, transport, context, events, connected, accepted, final, subscribers, transfer: new Transfer(context) };
}
for (const handshakeFirst of [false, true]) {
  test('TLS LIST supports handshake before/after command acceptance: ' + handshakeFirst, async () => {
    const f = fixture();
    await f.transfer.prepare();
    assert.deepEqual(f.events, ['tcp-connect']);
    const bytes = [];
    const result = f.transfer.input('LIST /', -1, data => bytes.push(...new Uint8Array(data)));
    assert.deepEqual(f.events, ['tcp-connect', 'connect', 'LIST /']);
    if (handshakeFirst) { f.connected.resolve(); await tick(); }
    f.accepted.resolve({ code: 150, message: 'ready' });
    await tick();
    assert.ok(f.events.includes('listen-final'));
    if (!handshakeFirst) f.connected.resolve();
    await tick();
    f.socket.emit([1, 2, 3]);
    f.socket.connected = false;
    f.final.resolve({ code: 226, message: 'done' });
    assert.equal((await result).code, 226);
    assert.deepEqual(bytes, [1, 2, 3]);
    await f.transfer.close();
    assert.equal(f.context.closes, 0);
    assert.equal(f.subscribers.size, 0);
  });
}
for (const handshakeFirst of [false, true]) {
  test('TLS STOR waits for both handshake and command acceptance: ' + handshakeFirst, async () => {
    const f = fixture(); await f.transfer.prepare(); let reads = 0;
    const result = f.transfer.output('STOR /x', async buffer => {
      reads++; new Uint8Array(buffer)[0] = 7; return reads === 1 ? 1 : 0;
    });
    if (handshakeFirst) f.connected.resolve(); else f.accepted.resolve({ code: 125, message: 'ready' });
    await tick(); assert.equal(reads, 0);
    if (handshakeFirst) f.accepted.resolve({ code: 150, message: 'ready' }); else f.connected.resolve();
    await tick(); assert.equal(reads, 2); assert.ok(f.events.includes('data:1'));
    f.final.resolve({ code: 226, message: 'done' }); await result; await f.transfer.close();
    assert.equal(f.context.closes, 0);
  });
}
test('plain FTP still establishes TCP in prepare', async () => {
  const f = fixture(false); const prepare = f.transfer.prepare(); await tick();
  assert.deepEqual(f.events, ['connect']); f.connected.resolve(); await prepare;
  const result = f.transfer.input('LIST', -1, () => {});
  f.accepted.resolve({ code: 150, message: 'ready' }); await tick();
  f.socket.connected = false; f.final.resolve({ code: 226, message: 'done' });
  await result; assert.equal(f.events.filter(e => e === 'connect').length, 1); await f.transfer.close();
});
test('final 226 is observed even before handshake promise resolves', async () => {
  const f = fixture(); await f.transfer.prepare();
  const result = f.transfer.input('LIST', -1, () => {});
  f.accepted.resolve({ code: 150, message: 'ready' }); await tick();
  f.final.resolve({ code: 226, message: 'done' }); await tick();
  f.connected.resolve(); await tick(); f.socket.connected = false;
  assert.equal((await result).code, 226); await f.transfer.close();
});
test('server 522 rejects immediately while data handshake is pending', async () => {
  const f = fixture(); await f.transfer.prepare();
  const result = rejects(f.transfer.input('LIST', -1, () => {}), /522/);
  f.accepted.resolve({ code: 150, message: 'ready' }); await tick();
  f.final.resolve({ code: 522, message: '522 TLS rejected' }); await result;
  assert.equal(f.socket.closes, 1); assert.equal(f.context.closes, 0);
});
test('command rejection cancels data handshake without poisoning control response stream', async () => {
  const f = fixture(); await f.transfer.prepare();
  const result = rejects(f.transfer.input('LIST', -1, () => {}), /550/);
  f.accepted.resolve({ code: 550, message: '550 denied' }); await result;
  assert.equal(f.socket.closes, 1); assert.equal(f.context.closes, 0);
});
test('handshake error closes unsynchronized control connection', async () => {
  const f = fixture(); await f.transfer.prepare();
  const result = rejects(f.transfer.input('LIST', -1, () => {}), /bad TLS/);
  f.connected.reject(new Error('bad TLS')); await result; await tick();
  assert.equal(f.context.closes, 1);
});
test('idle transfer times out and closes both channels', async () => {
  const f = fixture(true, 25); await f.transfer.prepare();
  await rejects(f.transfer.input('LIST', -1, () => {}), /timed out/); await tick();
  assert.equal(f.socket.closes, 1); assert.equal(f.context.closes, 1);
});
test('cancel during handshake rejects promptly and blocks late data', async () => {
  const f = fixture(); await f.transfer.prepare(); let received = 0;
  const result = rejects(f.transfer.input('RETR /x', 3, () => { received++; }), /canceled/);
  await f.transfer.close(); await result;
  f.socket.emit([1]); assert.equal(received, 0); assert.equal(f.context.closes, 1);
});
test('cancel before transfer sends no command or handshake', async () => {
  const f = fixture(); await f.transfer.prepare(); await f.transfer.close();
  await rejects(f.transfer.input('LIST', -1, () => {}), /closed/); assert.deepEqual(f.events, ['tcp-connect']);
});
test('cancel while source is pending does not send its late result', async () => {
  const f = fixture(); await f.transfer.prepare(); const source = deferred();
  const result = rejects(f.transfer.output('STOR /x', () => source.promise), /canceled/);
  f.connected.resolve(); f.accepted.resolve({ code: 150, message: 'ready' }); await tick();
  await f.transfer.close(); source.resolve(1); await result; await tick();
  assert.equal(f.events.some(e => e.startsWith('data:')), false);
});
test('server 426 remains an upload failure after all source bytes have been sent', async () => {
  const f = fixture(); await f.transfer.prepare(); let reads = 0;
  const result = rejects(f.transfer.output('STOR /x', async () => ++reads === 1 ? 1 : 0), /426/);
  f.connected.resolve(); f.accepted.resolve({ code: 150, message: 'ready' }); await tick();
  assert.ok(f.events.includes('data:1'));
  f.final.resolve({ code: 426, message: '426 network stream failed' }); await result;
});
test('active uploads may exceed idle timeout', async () => {
  const f = fixture(true, 50); await f.transfer.prepare(); let reads = 0;
  const result = f.transfer.output('STOR /x', async () => {
    await new Promise(resolve => setTimeout(resolve, 20));
    if (++reads < 6) return 1;
    f.final.resolve({ code: 226, message: 'done' }); return 0;
  });
  f.connected.resolve(); f.accepted.resolve({ code: 150, message: 'ready' });
  await result; assert.equal(reads, 6); await f.transfer.close();
});

// 执行实际 TLS socket 生命周期，覆盖等待地址解析、绑定和握手时的取消。
function tlsFixture() {
  const sockets = [];
  let address = () => Promise.resolve({ address: '127.0.0.1', port: 21, family: 1 });
  class NativeSocket {
    constructor() { this.events = {}; this.handshake = deferred(); this.bound = deferred(); this.bound.resolve(); this.closes = 0; this.connectCalls = 0; this.boundReady = false; sockets.push(this); }
    on(name, listener) { assert.equal(this.boundReady, true, "bind must complete before registering native TLS events"); this.events[name] = listener; }
    async bind() { await this.bound.promise; this.boundReady = true; }
    connect() { this.connectCalls++; return this.handshake.promise; }
    async setExtraOptions() {}
    async getState() { return { isConnected: this.closes === 0 }; }
    async close() { this.closes++; this.events.close?.(); }
  }
  const { FtpSocketTLSImpl } = load('socket/FtpSocketTLSImpl.ets', {
    '../FtpLogger': { default: logger }, '../FtpErrors': errors,
    '../FtpUtils': { FtpUtils: { buildNetAddress: () => address() } },
    '@kit.NetworkKit': { socket: { constructTLSSocketInstance: transport => {
      const socket = new NativeSocket();
      if (transport) socket.boundReady = true;
      return socket;
    } } },
    '@kit.ArkTS': { JSON }
  });
  return { sockets, FtpSocketTLSImpl, setAddress(fn) { address = fn; } };
}
test('TLS cancellation during DNS never constructs a socket afterwards', async () => {
  const f = tlsFixture(), dns = deferred(); f.setAddress(() => dns.promise);
  const socket = new f.FtpSocketTLSImpl({});
  const result = rejects(socket.connect('host', 21, 100), /canceled/);
  await tick(); await socket.close(); await result;
  dns.resolve({ address: '127.0.0.1', port: 21, family: 1 }); await tick(); assert.equal(f.sockets.length, 0);
});
test('TLS handshake timeout closes the socket and cancels the pending connection', async () => {
  const f = tlsFixture(), socket = new f.FtpSocketTLSImpl({});
  await rejects(socket.connect('host', 21, 20), /timed out/);
  assert.equal(f.sockets[0].closes, 1);
  f.sockets[0].handshake.resolve(); await tick();
  assert.equal(await socket.isConnected(), false);
});
test('TLS close during handshake rejects even if native connect never settles', async () => {
  const f = tlsFixture(), socket = new f.FtpSocketTLSImpl({});
  const result = rejects(socket.connect('host', 21, 100), /canceled/); await tick();
  await socket.close(); await result; assert.equal(f.sockets[0].closes, 1);
});
test('TLS reconnect cancels the previous handshake and uses the new socket', async () => {
  const f = tlsFixture(), socket = new f.FtpSocketTLSImpl({});
  const first = rejects(socket.connect('host', 21, 100), /canceled/); await tick();
  const second = socket.connect('host', 21, 100); await first; await tick();
  assert.equal(f.sockets[0].closes, 1);
  f.sockets[1].handshake.resolve(); await second;
  assert.equal(await socket.isConnected(), true); await socket.close();
});
test('TLS error during handshake rejects and closes the failed socket', async () => {
  const f = tlsFixture(), socket = new f.FtpSocketTLSImpl({});
  const result = rejects(socket.connect('host', 21, 100), /certificate/); await tick();
  f.sockets[0].events.error(new Error('certificate rejected')); await result;
  assert.equal(f.sockets[0].closes, 1);
});
test('canceling an upgrade before TLS creation also closes the raw TCP socket', async () => {
  const f = tlsFixture(), dns = deferred(); f.setAddress(() => dns.promise);
  const tcp = { closes: 0, async getState() { return { isConnected: true }; }, async close() { this.closes++; } };
  const socket = new f.FtpSocketTLSImpl({}, tcp);
  const result = rejects(socket.connect('host', 21, 100), /canceled/); await tick();
  await socket.close(); await result; assert.equal(tcp.closes, 1);
  dns.resolve({ address: '127.0.0.1', port: 21, family: 1 }); await tick();
});
function loadContext(dependencies = {}) {
  return load('FtpContextImpl.ets', {
  './FtpLogger': { default: logger }, './FtpErrors': errors, './parser/parseControlResponse': parser,
  './util/StringEncoding': { CharsetUtil: {
    encode(text) { return Uint8Array.from(Buffer.from(text)).buffer; },
    decode(bytes) { return Buffer.from(bytes).toString(); }
  } },
  './socket/FtpSocketTLSImpl': {}, './socket/FtpSocketTCPImpl': {},
  './transfer/FtpTransferIpv4Impl': {}, './transfer/FtpTransferIpv6Impl': {}, ...dependencies
  }).FtpContextImpl;
}
const FtpContextImpl = loadContext();
function controlFixture(timeout = 100) {
  const context = new FtpContextImpl(timeout), listeners = new Set();
  const socket = {
    closes: 0, sent: [],
    subscribeMessage(callback) { listeners.add(callback); return () => listeners.delete(callback); },
    async send(bytes) { socket.sent.push(Buffer.from(bytes).toString()); },
    async close() { socket.closes++; },
    emit(text) { [...listeners].forEach(callback => callback(Uint8Array.from(Buffer.from(text)).buffer)); }
  };
  context.commandSocket = socket;
  return { context, socket, listeners };
}
test('control retains coalesced 150 and 226 for separate consumers', async () => {
  const f = controlFixture(); const initial = f.context.send('LIST');
  f.socket.emit('150 ready\r\n226 done\r\n');
  assert.equal((await initial).code, 150);
  assert.equal((await f.context.consumeNextMessage()).code, 226);
  assert.equal(f.listeners.size, 1); await f.context.close();
  assert.equal(f.listeners.size, 0);
});
test('closing control rejects active and queued commands without hanging', async () => {
  const f = controlFixture();
  const first = rejects(f.context.send('LIST'), /closed/), second = rejects(f.context.send('PWD'), /closed/);
  await f.context.close(); await Promise.all([first, second]); await tick();
  assert.equal(f.listeners.size, 0); assert.equal(f.context.taskQueueRunning, false);
});
test('control response timeout removes listener and closes connection', async () => {
  const f = controlFixture(20); await rejects(f.context.send('EPSV'), /timed out/); await tick();
  assert.equal(f.listeners.size, 0); assert.equal(f.socket.closes, 1);
});
test('failed command write rejects its response wait and releases queue', async () => {
  const f = controlFixture(); f.socket.send = async () => { throw new Error('write failed'); };
  await rejects(f.context.send('LIST'), /write failed/); await tick();
  assert.equal(f.listeners.size, 0); assert.equal(f.context.taskQueueRunning, false);
});
test('peer TLS shutdown releases the native socket exactly once', async () => {
  const f = tlsFixture(), socket = new f.FtpSocketTLSImpl({});
  const connection = socket.connect('host', 21, 100); await tick();
  f.sockets[0].handshake.resolve(); await connection;
  f.sockets[0].events.close(); await tick();
  assert.equal(f.sockets[0].closes, 1); assert.equal(await socket.isConnected(), false);
  await socket.close(); assert.equal(f.sockets[0].closes, 1);
});
test('receiver callback error rejects transfer and closes both channels', async () => {
  const f = fixture(); await f.transfer.prepare();
  const result = rejects(f.transfer.input('RETR /x', 4, () => { throw new Error('consumer failed'); }), /consumer failed/);
  f.connected.resolve(); f.accepted.resolve({ code: 150, message: 'ready' }); await tick();
  f.socket.emit([1]); await result; assert.equal(f.context.closes, 1);
});


// 原生 send 回调与服务器响应独立推进，覆盖分包响应到达时暂时没有消费者的情况。
test('separate final reply is retained while native command send is still pending', async () => {
  const f = controlFixture(), sent = deferred();
  f.socket.send = () => sent.promise;
  const result = f.context.send('LIST').then(() => f.context.consumeNextMessage());
  const observed = result.then(response => response.code, error => error.message);
  f.socket.emit('150 ready\r\n'); await tick();
  f.socket.emit('226 done\r\n'); await tick();
  sent.resolve();
  assert.equal(await observed, 226);
  await f.context.close(); assert.equal(f.listeners.size, 0);
});
test('control responses are delivered once and in order to concurrent consumers', async () => {
  const f = controlFixture();
  const first = f.context.consumeNextMessage(), second = f.context.consumeNextMessage();
  f.socket.emit('150 ready\r\n226 done\r\n');
  assert.deepEqual((await Promise.all([first, second])).map(response => response.code), [150, 226]);
  await f.context.close();
});
test('closing control clears buffered replies and unsubscribes the old socket', async () => {
  const f = controlFixture(), next = controlFixture();
  const first = f.context.consumeNextMessage();
  f.socket.emit('150 ready\r\n226 old\r\n'); await first;
  await f.context.close();
  assert.equal(f.listeners.size, 0);
  f.context.commandSocket = next.socket;
  const current = f.context.consumeNextMessage();
  // 从 socket 正常派发消息，关闭时取消的监听不应再被调用。
  f.socket.emit('226 old\r\n');
  next.socket.emit('220 new\r\n');
  assert.equal((await current).code, 220);
  await f.context.close();
});
test('closing control cancels a pending command before the next connection is used', async () => {
  const f = controlFixture(), sent = deferred(), next = controlFixture();
  f.socket.send = () => sent.promise;
  f.socket.close = async () => { f.socket.closes++; sent.reject(new Error('socket closed')); };
  const first = rejects(f.context.send('PWD'), /closed/);
  await f.context.close();
  await first;
  f.context.commandSocket = next.socket;
  assert.equal(next.socket.closes, 0);
  const current = f.context.send('PWD'); next.socket.emit('257 /new\r\n');
  assert.equal((await current).message, '257 /new');
  await f.context.close();
});

function passiveFixture() {
  const listeners = new Set(), commands = [], transports = [];
  const nativeClose = deferred();
  let delayClose = false;
  let connectPending;
  let epsvPort = 50000;
  class Transport {
    constructor() { this._connected = false; this.closes = 0; this.closeSubscribers = new Set(); transports.push(this); }
    get connected() { return this._connected; }
    set connected(value) { const wasConnected = this._connected; this._connected = value; if (wasConnected && !value) this.closeSubscribers.forEach(callback => callback()); }
    subscribeClose(callback) { this.closeSubscribers.add(callback); return () => this.closeSubscribers.delete(callback); }
    hasTls() { return false; }
    async connect(address, port) {
      this.port = port;
      if (connectPending) await connectPending.promise;
      if (port === 50000) throw new Error('EPSV data endpoint refused');
      this.connected = true;
    }
    async isConnected() { return this.connected; }
    subscribeMessage() { return () => {}; }
    async close() { this.closes++; if (delayClose) await nativeClose.promise; this.connected = false; }
    useTls() {
      const transport = this;
      return {
        hasTls() { return true; },
        async connect() { assert.equal(transport.connected, true); },
        async isConnected() { return transport.connected; },
        subscribeMessage() { return () => {}; },
        subscribeClose(callback) { return transport.subscribeClose(callback); },
        async close() { await transport.close(); }
      };
    }
  }
  const AbsFtpTransfer = loadTransfer(Transport);
  const ipv4 = load('transfer/FtpTransferIpv4Impl.ets', {'../FtpErrors': errors, './AbsFtpTransfer': {AbsFtpTransfer}});
  const ipv6 = load('transfer/FtpTransferIpv6Impl.ets', {'../FtpErrors': errors, './AbsFtpTransfer': {AbsFtpTransfer}});
  const Context = loadContext({
    './transfer/FtpTransferIpv4Impl': ipv4, './transfer/FtpTransferIpv6Impl': ipv6
  });
  const control = {
    closes: 0,
    async isConnected() { return control.closes === 0; },
    async getRemoteAddress() { return {address: '127.0.0.1', family: 1, port: 21}; },
    subscribeMessage(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    async send(bytes) {
      const command = Buffer.from(bytes).toString().trim(); commands.push(command);
      const reply = command === 'EPSV' ? `229 Entering Extended Passive Mode (|||${epsvPort}|)\r\n` :
        command === 'PASV' ? '227 Entering Passive Mode (127,0,0,1,195,81)\r\n' :
        command === 'LIST' ? '150 opening data\r\n' : undefined;
      if (reply) setImmediate(() => control.emit(reply));
    },
    emit(text) { [...listeners].forEach(fn => fn(Uint8Array.from(Buffer.from(text)).buffer)); },
    async close() { control.closes++; }
  };
  const context = new Context(100);
  context.commandSocket = control; context.dataSocketUseTls = true;
  return {context, control, commands, transports, nativeClose,
    delayClosing() {delayClose = true;}, useWorkingEPSV() {epsvPort = 50001;},
    delayConnecting(pending) {connectPending = pending;}};
}
test('FTPS retries PASV when EPSV advertises an unreachable data port', async () => {
  const f = passiveFixture();
  const transfer = await f.context.prepareTransfer();
  assert.deepEqual(f.commands, ['EPSV', 'PASV']);
  assert.equal(f.transports[0].closes, 1);
  assert.equal(f.transports[1].port, 50001);
  const result = transfer.input('LIST', -1, () => {});
  await tick(); await tick();
  f.transports[1].connected = false; f.control.emit('226 done\r\n');
  assert.equal((await result).code, 226);
  await transfer.close(); await f.context.close();
});
for (const closeContext of [false, true]) {
  test('cancellation waits for data cleanup without recursive close deadlock: ' + closeContext, async () => {
    const f = passiveFixture(); f.useWorkingEPSV();
    const transfer = await f.context.prepareTransfer();
    const running = (async () => {
      try { await transfer.input('LIST', -1, () => {}); }
      finally { await transfer.close(); }
    })();
    let settled = false;
    const canceled = rejects(running, /canceled|closed/).then(() => { settled = true; });
    await tick(); await tick();
    f.delayClosing();
    const closing = closeContext ? f.context.close() : transfer.close();
    await tick();
    assert.equal(settled, false);
    assert.equal(await f.context.isConnected(), false);
    await rejects(f.context.send('PWD'), /not ready|closed/);
    f.nativeClose.resolve(); await Promise.all([closing, canceled]);
    assert.equal(f.transports[0].closes, 1);
    assert.equal(f.context.transfer, undefined);
    const next = controlFixture(); f.context.commandSocket = next.socket;
    const command = f.context.send('PWD'); await tick();
    assert.equal(next.socket.sent.length, 1); next.socket.emit('257 /new\r\n');
    assert.equal((await command).code, 257); assert.equal(next.socket.closes, 0);
    await f.context.close();
  });
}
test('cancel before TLS handshake closes the already connected TCP transport', async () => {
  const f = tlsFixture();
  const tcp = {closes: 0, async close() {this.closes++;}};
  const socket = new f.FtpSocketTLSImpl({}, tcp);
  await socket.close(); await socket.close();
  assert.equal(tcp.closes, 1); assert.equal(f.sockets.length, 0);
});

test('a failed native control close does not poison later cleanup or reconnect', async () => {
  const f = controlFixture();
  f.socket.close = async () => { throw new Error('native close failed'); };
  await rejects(f.context.close(), /native close failed/);
  await f.context.close();
  const next = controlFixture(); f.context.commandSocket = next.socket;
  const result = f.context.send('PWD'); next.socket.emit('257 /new\r\n');
  assert.equal((await result).code, 257); await f.context.close();
});
test('TCP upgrade transfers ownership to TLS without closing the raw transport twice', async () => {
  const f = tlsFixture();
  const tcp = {closes: 0, async getState() {return {isConnected: true};}, async close() {this.closes++;}};
  const socket = new f.FtpSocketTLSImpl({}, tcp);
  const connection = socket.connect('host', 21, 100); await tick();
  f.sockets[0].handshake.resolve(); await connection;
  await socket.close(); await socket.close();
  assert.equal(f.sockets[0].closes, 1); assert.equal(tcp.closes, 0);
});

test('canceled data preparation cannot retry PASV on a replacement control session', async () => {
  const f = passiveFixture(), connected = deferred(); f.useWorkingEPSV(); f.delayConnecting(connected);
  const prepared = rejects(f.context.prepareTransfer(), /canceled|closed/);
  await tick(); await tick();
  assert.equal(f.transports.length, 1);
  await f.context.close();
  const next = controlFixture(); f.context.commandSocket = next.socket;
  connected.resolve(); await prepared; await tick();
  assert.deepEqual(next.socket.sent, []); assert.equal(next.socket.closes, 0);
  await f.context.close();
});

// 控制连接的完成响应不能代替数据连接的 EOF，目录读取必须等两个条件都满足。
test('LIST waits for real EOF even when 226 precedes data by more than 200 ms', async () => {
  const f = fixture(true, 1500); await f.transfer.prepare(); const bytes = []; let settled = false;
  const result = f.transfer.input('LIST', -1, data => bytes.push(...new Uint8Array(data))).then(value => { settled = true; return value; });
  f.connected.resolve(); f.accepted.resolve({code: 150, message: 'ready'}); await tick();
  f.socket.emit([1]); f.final.resolve({code: 226, message: 'done'});
  await new Promise(resolve => setTimeout(resolve, 300));
  assert.equal(settled, false); f.socket.emit([2, 3]); f.socket.connected = false;
  await result; assert.deepEqual(bytes, [1, 2, 3]); await f.transfer.close();
});
test('RETR rejects a premature EOF instead of accepting truncated bytes', async () => {
  const f = fixture(); await f.transfer.prepare();
  const result = rejects(f.transfer.input('RETR /file', 4, () => {}), /length mismatch/);
  f.connected.resolve(); f.accepted.resolve({code: 150, message: 'ready'}); await tick();
  f.socket.emit([1, 2]); f.socket.connected = false; f.final.resolve({code: 226, message: 'done'});
  await result;
});
test('LIST with final reply but no EOF times out instead of returning an empty directory', async () => {
  const f = fixture(true, 40); await f.transfer.prepare();
  const result = rejects(f.transfer.input('LIST', -1, () => {}), /timed out/);
  f.connected.resolve(); f.accepted.resolve({code: 150, message: 'ready'}); await tick();
  f.final.resolve({code: 226, message: 'done'}); await result;
});

// 单文件查询走控制通道，覆盖上传后立即查询、中文路径和旧服务端兼容行为。
const fileModels = load('models/FileInfo.ts', {});
const mlsd = load('parser/parseListMLSD.ts', { '../models/FileInfo': fileModels });
function statFixture(responses, features = ['MLST']) {
  const commands = [];
  class Context {
    hasFeature(name) { return features.includes(name); }
    async send(command) {
      commands.push(command);
      assert.ok(command in responses, 'Unexpected FTP command: ' + command);
      return responses[command];
    }
  }
  const Client = load('FtpClient.ets', {
    './models/FileInfo': fileModels, './FtpContextImpl': { FtpContextImpl: Context },
    './parser/parseControlResponse': parser, './FtpLogger': { default: logger },
    './util/StringEncoding': {}, './parser/parseList': {}, './FtpErrors': errors,
    './parser/parseListMLSD': mlsd
  }).FtpClient;
  return { client: new Client(), commands };
}
test('MLST queries the exact Chinese path and preserves zero size and timestamp', async () => {
  const f = statFixture({ 'MLST /测试/ a %.txt': { code: 250,
    message: '250-Listing\r\n type=file;size=0;modify=20261005010203; /测试/ a %.txt\r\n250 End' } });
  const info = await f.client.stat('/测试/ a %.txt');
  assert.equal(info.name, ' a %.txt');
  assert.equal(info.size, 0);
  assert.equal(info.modifiedAt.toISOString(), '2026-10-05T01:02:03.000Z');
  assert.deepEqual(f.commands, ['MLST /测试/ a %.txt']);
});
test('MLST cdir represents a directory in stat', async () => {
  const f = statFixture({ 'MLST /folder/': { code: 250, message: '250-ok\n type=cdir; /folder/\n250 End' } });
  const info = await f.client.stat('/folder/');
  assert.equal(info.name, 'folder');
  assert.equal(info.isDirectory, true);
});
test('SIZE and MDTM query regular files without directory listing', async () => {
  const f = statFixture({ 'SIZE /file': { code: 213, message: '213 17' },
    'MDTM /file': { code: 213, message: '213 20261005010203.123' } }, []);
  const info = await f.client.stat('/file');
  assert.equal(info.size, 17);
  assert.equal(info.modifiedAt.getUTCMilliseconds(), 123);
  assert.deepEqual(f.commands, ['SIZE /file', 'MDTM /file']);
});
test('MLST unsupported falls back to exact SIZE without requiring MDTM support', async () => {
  const f = statFixture({ 'MLST /file': { code: 502, message: '502 unsupported' },
    'SIZE /file': { code: 213, message: '213 0' }, 'MDTM /file': { code: 502, message: '502 unsupported' } });
  assert.equal((await f.client.stat('/file')).size, 0);
});
test('stat does not turn server errors or malformed metadata into missing files', async () => {
  for (const response of [{ code: 451, message: '451 temporary failure' },
    { code: 250, message: '250 missing facts' }]) {
    const f = statFixture({ 'MLST /file': response });
    await assert.rejects(f.client.stat('/file'), error => error.name === 'FtpError');
  }
  const f = statFixture({ 'SIZE /file': { code: 213, message: '213 invalid' } }, []);
  await rejects(f.client.stat('/file'), /Invalid SIZE/);
});
test('legacy directory fallback includes hidden files and propagates listing errors', async () => {
  const f = statFixture({ 'MLST /hidden/.test': { code: 550, message: '550 unavailable' },
    'SIZE /hidden/.test': { code: 550, message: '550 unavailable' } });
  f.client.list = async (parent, hidden) => {
    assert.equal(parent, '/hidden'); assert.equal(hidden, true);
    return [new fileModels.FileInfo('.test')];
  };
  assert.equal((await f.client.stat('/hidden/.test')).name, '.test');
  f.client.list = async () => { throw new Error('permission denied'); };
  await rejects(f.client.stat('/hidden/.test'), /permission denied/);
});
test('TCP peer close releases its descriptor once and TLS owns an upgraded descriptor', async () => {
  const callbacks = {}, events = [];
  let closes = 0;
  const native = {on(name, action) {callbacks[name] = action;}, async bind() {}, async connect() {},
    async setExtraOptions() {}, async close() {closes++; await callbacks.close();}};
  const {FtpSocketTCPImpl} = load('socket/FtpSocketTCPImpl.ets', {
    '@kit.NetworkKit': {socket: {constructTCPSocketInstance: () => native}},
    './FtpSocketTLSImpl': {FtpSocketTLSImpl: class {constructor(options, transport) {this.transport = transport;}}}, '../FtpLogger': {default: logger},
    '../FtpUtils': {FtpUtils: {async buildNetAddress() {return {address:'127.0.0.1', family:1};}}},
    '../FtpErrors': errors
  });
  const socket = new FtpSocketTCPImpl();
  socket.subscribeMessage(data => events.push('data:' + data.byteLength));
  socket.subscribeClose(() => events.push('eof'));
  await socket.connect('127.0.0.1', 21, 500);
  callbacks.message({message: new ArrayBuffer(1)});
  await callbacks.close();
  await socket.close();
  assert.equal(closes, 1);
  assert.deepEqual(events, ['data:1', 'eof']);
  await socket.connect('127.0.0.1', 21, 500);
  assert.equal(socket.useTls({}).transport, native);
  await callbacks.close();
  await socket.close();
  assert.equal(closes, 1); // 升级后描述符由 TLS 独占。
});
