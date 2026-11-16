/* 本地渲染验证：静态服务 + 无头 Edge（CDP 驱动），收集页面自检结果与四页截图。 */
const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const WEBROOT = path.join(ROOT, 'module', 'webroot');
const OUT = path.join(ROOT, 'dist', 'preview');
const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';

function buildSite(dir, failApps, unknownRefresh) {
  fs.mkdirSync(dir, { recursive: true });
  for (const f of ['style.css', 'core.js', 'app.js']) fs.copyFileSync(path.join(WEBROOT, f), path.join(dir, f));
  fs.copyFileSync(path.join(__dirname, 'mock-bridge.js'), path.join(dir, 'mock-bridge.js'));
  const flags = (failApps ? '<script>window.NANHE_MOCK_FAIL_APPS=true;</script>\n  ' : '') +
    (unknownRefresh ? '<script>window.NANHE_MOCK_REFRESH_UNKNOWN=true;</script>\n  ' : '');
  fs.writeFileSync(path.join(dir, 'index.html'), fs.readFileSync(path.join(WEBROOT, 'index.html'), 'utf8')
    .replace(/<meta http-equiv="Content-Security-Policy"[^>]*>\n?/, '')
    .replace('<script src="core.js" defer></script>', flags + '<script src="mock-bridge.js"></script>\n  <script src="core.js" defer></script>'));
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png' };
function serve(dir) {
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
    const file = path.join(dir, rel);
    if (!file.startsWith(dir) || !fs.existsSync(file)) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}
function freePort() {
  return new Promise(resolve => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function getJSON(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(url + ' -> ' + res.status);
  return res.json();
}

class Cdp {
  constructor(url) { this.url = url; this.id = 0; this.pending = new Map(); this.events = []; }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => resolve();
      this.ws.onerror = e => reject(new Error('WebSocket 连接失败: ' + (e.message || e.type)));
      this.ws.onmessage = m => {
        const msg = JSON.parse(m.data);
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve: ok, reject: bad } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          if (msg.error) bad(new Error(msg.method + ': ' + JSON.stringify(msg.error))); else ok(msg.result);
        } else if (msg.method) this.events.push(msg);
      };
    });
  }
  send(method, params) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params: params || {} }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(method + ' 超时')); } }, 20000);
    });
  }
  async evaluate(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error('页面表达式异常: ' + JSON.stringify(r.exceptionDetails.exception || r.exceptionDetails.text));
    return r.result.value;
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const site = path.join(OUT, 'site');
  buildSite(site, false);
  const siteBad = path.join(OUT, 'site-degraded');
  buildSite(siteBad, true);
  const siteUnknown = path.join(OUT, 'site-unknown-refresh');
  buildSite(siteUnknown, false, true);
  const server = await serve(site);
  const serverBad = await serve(siteBad);
  const serverUnknown = await serve(siteUnknown);
  const base = 'http://127.0.0.1:' + server.address().port;
  const baseBad = 'http://127.0.0.1:' + serverBad.address().port;
  const baseUnknown = 'http://127.0.0.1:' + serverUnknown.address().port;
  const port = await freePort();
  // profile 放到 dist/preview 下（D 盘）而不是系统临时目录（C 盘），
  // 并且结束一定删掉：Edge 的每个 profile 会带 ~479 MB 缓存，泄漏几次就能把系统盘写满。
  const profile = fs.mkdtempSync(path.join(OUT, 'edge-profile-'));
  const browser = spawn(EDGE, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=' + profile, '--remote-debugging-port=' + port, '--window-size=430,900', 'about:blank'],
    { stdio: 'ignore', detached: false });

  const results = [];
  let cdp;
  try {
    let version = null;
    for (let i = 0; i < 40 && !version; i++) {
      try { version = await getJSON('http://127.0.0.1:' + port + '/json/version'); }
      catch (_) { await sleep(500); }
    }
    if (!version) throw new Error('无头 Edge 未能启动 CDP 端口');
    const list = await getJSON('http://127.0.0.1:' + port + '/json/list');
    const page = list.find(t => t.type === 'page' && t.url === 'about:blank') || list.find(t => t.type === 'page');
    if (!page) throw new Error('没有可用的页面 target');

    cdp = new Cdp(page.webSocketDebuggerUrl);
    await cdp.connect();
    await cdp.send('Runtime.enable');
    await cdp.send('Page.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 430, height: 900, deviceScaleFactor: 2, mobile: true });
    await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await cdp.send('Page.navigate', { url: base + '/' });
    for (let i = 0; i < 40; i++) {
      if (await cdp.evaluate('document.readyState')) {
        if ((await cdp.evaluate('document.readyState')) === 'complete') break;
      }
      await sleep(250);
    }
    await sleep(2500); // 等 refresh() 的桥接回调与渲染完成

    const checks = await cdp.evaluate(`(() => {
      const q = id => document.getElementById(id);
      return {
        modeButtons: document.querySelectorAll('.mode-button').length,
        activeMode: document.querySelectorAll('.mode-button.active').length,
        summary: document.querySelectorAll('.summary-card').length,
        freqCards: document.querySelectorAll('#frequency-list .card').length,
        tierChips: document.querySelectorAll('#refresh-tiers .tier-chip').length,
        tierDisabled: [...document.querySelectorAll('#refresh-tiers .tier-chip.unsupported')].filter(b => b.disabled && b.getAttribute('aria-disabled') === 'true').length,
        tierActive: [...document.querySelectorAll('#refresh-tiers .tier-chip.active')].map(b => b.textContent).join('|'),
        refreshCurrent: q('refresh-current').textContent,
        pin: q('pin-switch').getAttribute('aria-checked'),
        pinDisabled: q('pin-switch').disabled,
        devCards: document.querySelectorAll('#device-info .info-card').length,
        devRows: document.querySelectorAll('#device-info .details > div').length,
        devScreen: (document.querySelector('#device-info dd') || {}).textContent || '',
        refreshInPage: q('page-frequency').contains(document.querySelector('.refresh-card')),
        restoreInPage: q('page-frequency').contains(document.querySelector('.restore-card')),
        devInPage: q('page-about').contains(q('device-info')),
        appRows: document.querySelectorAll('#app-list .rule-row').length,
        special: document.querySelectorAll('#special-rules .rule-row').length,
        tune: q('tune-switch').getAttribute('aria-checked'),
        infoRows: q('system-info').children.length,
        version: q('about-version').textContent,
        conn: q('connection-text').textContent,
        noticeHidden: q('notice').hidden,
        live: q('connection').classList.contains('live'),
        radius: getComputedStyle(q('mode-grid').children[0]).borderRadius,
        accent: getComputedStyle(document.documentElement).getPropertyValue('--accent').trim(),
        scrollWidth: document.documentElement.scrollWidth,
        title: q('page-title').textContent,
        modeNames: [...document.querySelectorAll('.mode-name')].map(n => n.textContent).join('|'),
        nav: (() => { const s = getComputedStyle(document.querySelector('.bottom-nav')); return { position: s.position, bottom: s.bottom, radius: s.borderRadius, width: s.width, blur: s.backdropFilter || s.webkitBackdropFilter }; })(),
        glass: (() => { const s = getComputedStyle(document.querySelector('#page-overview .card')); return s.backdropFilter || s.webkitBackdropFilter; })(),
        statusState: q('status-card').dataset.state,
        statusTitle: q('overview-heading').textContent,
        statRules: q('stat-rules').textContent,
        statDevices: q('stat-devices').textContent,
        shellPad: getComputedStyle(document.querySelector('.app-shell')).paddingBottom,
        refreshNote: q('refresh-note').textContent,
        logRows: document.querySelectorAll('#log-list .log-row').length,
        logLevels: [...document.querySelectorAll('#log-list .log-level')].map(n => n.textContent).join('|'),
        logInPage: q('page-about').contains(q('log-list')),
        logCount: q('log-count').textContent,
        logClearDisabled: q('log-clear').disabled,
        logsApi: window.NANHE_MOCK_LOGS ? window.NANHE_MOCK_LOGS.length : -1
      };
    })()`);

    const ok = {
      '模式按钮 4 个（后端驱动）': checks.modeButtons === 4,
      '唯一模式高亮': checks.activeMode === 1,
      '模式名来自后端': checks.modeNames === '省电|均衡|性能|极速',
      '运行快照 4 张': checks.summary === 4,
      '频率卡片 4 张': checks.freqCards === 4,
      '刷新率档位 10 个': checks.tierChips === 10,
      '不支持的 7 个档位置灰并禁用': checks.tierDisabled === 7,
      '当前目标档位 120Hz 高亮': checks.tierActive === '120Hz',
      '当前刷新率显示 120 Hz': checks.refreshCurrent === '120 Hz',
      '已设目标时锁定开关可点': checks.pin === 'false' && checks.pinDisabled === false,
      '机型信息卡片 >= 7 组': checks.devCards >= 7,
      '机型信息行 >= 14 条': checks.devRows >= 14,
      '首行为设备品牌': checks.devScreen === 'REDMI',
      '刷新率与恢复卡片在频率页内': checks.refreshInPage === true && checks.restoreInPage === true,
      '机型信息在关于页内': checks.devInPage === true,
      '特殊规则 2 条': checks.special === 2,
      '应用规则行 >= 3': checks.appRows >= 3,
      '调优开关已打开': checks.tune === 'true',
      '设备信息 >= 7 条': checks.infoRows >= 7,
      '版本号来自后端': checks.version === 'v1.3.2',
      '关于页有运行日志（>= 3 条）': checks.logRows >= 3 && checks.logInPage === true,
      '日志保留级别标签（注意 / 异常）': checks.logLevels.indexOf('注意') >= 0 && checks.logLevels.indexOf('异常') >= 0,
      '日志数量与后端一致': checks.logCount.indexOf('3 条') >= 0 && checks.logsApi === 3,
      '日志操作按钮在已连接时可点': checks.logClearDisabled === false,
      'Root 已连接': checks.conn.startsWith('Root 已连接') && checks.live === true,
      '无错误提示条': checks.noticeHidden === true,
      '卡片圆角 >= 20px': parseFloat(checks.radius) >= 20,
      '主色为 Miuix 蓝': ['#3482ff', '#6da6ff'].includes(checks.accent),
      '无横向溢出': checks.scrollWidth <= 430,
      '标题正确': checks.title === '设备总览',
      '底部导航为悬浮胶囊': checks.nav.position === 'fixed' && parseFloat(checks.nav.bottom) >= 8 && parseFloat(checks.nav.radius) >= 28,
      '底部导航不贴满屏宽': parseFloat(checks.nav.width) <= 430,
      '底栏是液态玻璃（有背景模糊）': String(checks.nav.blur).indexOf('blur(') >= 0,
      '其它卡片为实色 Miuix 白卡（不铺玻璃）': !String(checks.glass).includes('blur('),
      '首页显示绿色「工作中」状态卡': checks.statusState === 'run' && checks.statusTitle === '工作中',
      '状态卡统计数字来自后端': checks.statRules !== '0' && checks.statDevices === '4',
      '内容底部为悬浮底栏留出空间': parseFloat(checks.shellPad) >= 120,
    };
    for (const [k, v] of Object.entries(ok)) results.push((v ? 'PASS ' : 'FAIL ') + k + (v ? '' : '（实际 ' + JSON.stringify(checks) + '）'));

    const errors = cdp.events.filter(e => e.method === 'Runtime.exceptionThrown');
    results.push((errors.length ? 'FAIL ' : 'PASS ') + '页面无未捕获异常' + (errors.length ? '（' + JSON.stringify(errors[0].params) + '）' : ''));

    for (const [name, hash, height] of [['overview', '', 1450], ['frequency', '#frequency', 2200], ['apps', '#apps', 1450], ['about', '#about', 3000]]) {
      await cdp.evaluate(`location.hash='${hash}'`);
      await sleep(600);
      const visible = await cdp.evaluate("[...document.querySelectorAll('.page')].filter(p => !p.hidden).map(p => p.id).join('|')");
      results.push((visible === 'page-' + name ? 'PASS ' : 'FAIL ') + '只显示 ' + name + ' 一页（实际 ' + visible + '）');
      await cdp.send('Emulation.setDeviceMetricsOverride', { width: 430, height, deviceScaleFactor: 2, mobile: true });
      await sleep(400);
      const shot = await cdp.send('Page.captureScreenshot', { format: 'png' });
      const file = path.join(OUT, 'ui-' + name + '.png');
      fs.writeFileSync(file, Buffer.from(shot.data, 'base64'));
      results.push((fs.statSync(file).size > 30000 ? 'PASS ' : 'FAIL ') + '截图 ' + name + '（' + fs.statSync(file).size + ' 字节）');
    }

    // 深色参考图：切换媒体特性后整页重载
    await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 430, height: 1500, deviceScaleFactor: 2, mobile: true });
    await cdp.send('Page.navigate', { url: base + '/' });
    await sleep(2600);
    const darkShot = await cdp.send('Page.captureScreenshot', { format: 'png' });
    const darkFile = path.join(OUT, 'ui-dark.png');
    fs.writeFileSync(darkFile, Buffer.from(darkShot.data, 'base64'));
    results.push((fs.statSync(darkFile).size > 30000 ? 'PASS ' : 'FAIL ') + '截图 dark（' + fs.statSync(darkFile).size + ' 字节）');

    // 真机场景回归：apps 失败（pm list packages 退出 1）时，设备状态仍必须可用
    await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 430, height: 900, deviceScaleFactor: 2, mobile: true });
    await cdp.send('Page.navigate', { url: baseBad + '/#apps' });
    await sleep(2600);
    const degraded = await cdp.evaluate(`(() => {
      const q = id => document.getElementById(id);
      return {
        live: q('connection').classList.contains('live'),
        conn: q('connection-text').textContent,
        notice: q('notice').hidden ? '' : q('notice').textContent,
        appRows: document.querySelectorAll('#app-list .rule-row').length,
        empty: [...document.querySelectorAll('#app-list .empty')].map(n => n.textContent).join('|'),
        freqCards: document.querySelectorAll('#frequency-list .card').length
      };
    })()`);
    results.push((degraded.live && degraded.conn.startsWith('Root 已连接') ? 'PASS ' : 'FAIL ') +
      '应用清单失败仍识别设备' + (degraded.live ? '' : '（实际 ' + JSON.stringify(degraded) + '）'));
    results.push((degraded.notice.indexOf('应用清单读取失败') >= 0 ? 'PASS ' : 'FAIL ') +
      '应用清单失败给出提示' + (degraded.notice ? '' : '（无提示）'));
    results.push((degraded.appRows === 0 && degraded.empty.indexOf('未能枚举到应用包名') >= 0 ? 'PASS ' : 'FAIL ') +
      '应用清单为空时有说明' + (degraded.appRows === 0 && degraded.empty.indexOf('未能枚举到应用包名') >= 0 ? '' :
        '（实际 ' + degraded.appRows + ' 行 / ' + JSON.stringify(degraded.empty) + '）'));
    results.push((degraded.freqCards === 4 ? 'PASS ' : 'FAIL ') +
      '应用清单失败不影响频率页' + (degraded.freqCards === 4 ? '' : '（实际 ' + degraded.freqCards + ' 张）'));

    // 真机场景回归：后端读不到刷新率档位表时，不能把 10 个档位全部禁用
    await cdp.send('Page.navigate', { url: baseUnknown + '/#frequency' });
    await sleep(2600);
    const unknown = await cdp.evaluate(`(() => {
      const q = id => document.getElementById(id);
      return {
        tiers: document.querySelectorAll('#refresh-tiers .tier-chip').length,
        disabled: document.querySelectorAll('#refresh-tiers .tier-chip.unsupported').length,
        note: q('refresh-note').textContent
      };
    })()`);
    results.push((unknown.tiers === 10 && unknown.disabled === 0 ? 'PASS ' : 'FAIL ') +
      '读不到档位表时不置灰任何档位' + (unknown.tiers === 10 && unknown.disabled === 0 ? '' :
        '（实际 ' + unknown.tiers + ' 档 / ' + unknown.disabled + ' 个置灰）'));
    results.push((unknown.note.indexOf('放开全部档位') >= 0 ? 'PASS ' : 'FAIL ') +
      '读不到档位表时说明已放开全部档位' + (unknown.note.indexOf('放开全部档位') >= 0 ? '' : '（实际 ' + JSON.stringify(unknown.note) + '）'));

    // 底栏玻璃的交互：高光跟随指针（只有底栏保留玻璃）
    const glow = await cdp.evaluate(`(() => {
      const nav = document.querySelector('.bottom-nav');
      const box = nav.getBoundingClientRect();
      const before = getComputedStyle(nav).getPropertyValue('--spec-x').trim();
      nav.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: box.left + box.width * 0.2, clientY: box.top + box.height * 0.5 }));
      return { before, after: getComputedStyle(nav).getPropertyValue('--spec-x').trim(), box: [box.left, box.top], width: box.width };
    })()`);
    await cdp.evaluate(`(() => {
      const card = document.querySelector('#page-frequency .card');
      const box = card.getBoundingClientRect();
      card.style.transition = 'none';
      card.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: box.left + 12, clientY: box.top + 12 }));
    })()`);
    await sleep(140);
    const pressed = await cdp.evaluate(`(() => {
      const card = document.querySelector('#page-frequency .card');
      const m = getComputedStyle(card).transform;
      const a = m && m !== 'none' ? parseFloat(m.slice(m.indexOf('(') + 1)) : 1;
      const out = { scaleA: a, transform: m, filter: getComputedStyle(card).filter, pressed: card.classList.contains('pressing'), transition: getComputedStyle(card).transitionProperty };
      card.style.removeProperty('transition');
      return out;
    })()`);
    await cdp.evaluate(`(() => {
      const card = document.querySelector('#page-frequency .card');
      card.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, clientX: 10, clientY: 10 }));
    })()`);
    const released = await cdp.evaluate(`(() => {
      const card = document.querySelector('#page-frequency .card');
      return { pressing: card.classList.contains('pressing'), refract: getComputedStyle(document.documentElement).getPropertyValue('--refract-h').trim(), chroma: getComputedStyle(document.documentElement).getPropertyValue('--chroma-a').trim() };
    })()`);
    results.push((glow.after === '20.0%' && glow.before !== glow.after ? 'PASS ' : 'FAIL ') +
      '高光位置跟随指针' + (glow.after === '20.0%' ? '' : '（实际 before=' + glow.before + ' after=' + glow.after + '）'));
    results.push((pressed.pressed && pressed.scaleA < 1 ? 'PASS ' : 'FAIL ') +
      '按下时收缩并带弹簧回弹' + (pressed.pressed && pressed.scaleA < 1 ? '' : '（实际 pressed=' + pressed.pressed + ' transform=' + pressed.transform + ' filter=' + pressed.filter + '）'));
    results.push((!released.pressing ? 'PASS ' : 'FAIL ') + '松开后移除按压缩放');
    results.push((released.refract === '16px' && released.chroma.length > 0 ? 'PASS ' : 'FAIL ') +
      '折射带厚度与色散参数已定义' + (released.refract === '16px' ? '' : '（实际 ' + released.refract + '）'));

    // 底栏液态玻璃：镜片胶囊随页面切换滑到对应格；滚动时玻璃带倾斜/拉伸反馈
    await cdp.evaluate(`(() => { location.hash = '#apps'; })()`);
    await sleep(240);
    const lens = await cdp.evaluate(`(() => {
      const nav = document.querySelector('.bottom-nav');
      return { index: getComputedStyle(nav).getPropertyValue('--nav-index').trim(), left: document.querySelector('.nav-lens').getBoundingClientRect().left, navLeft: nav.getBoundingClientRect().left };
    })()`);
    await cdp.evaluate(`(() => { location.hash = '#frequency'; window.scrollTo(0, 0); })()`);
    await sleep(200);
    await cdp.evaluate(`(() => { window.scrollTo(0, 640); })()`);
    await sleep(200);
    const liquid = await cdp.evaluate(`(() => {
      const nav = document.querySelector('.bottom-nav');
      return { skew: getComputedStyle(nav).getPropertyValue('--nav-skew').trim(), stretch: getComputedStyle(nav).getPropertyValue('--nav-stretch').trim(), spec: getComputedStyle(nav).getPropertyValue('--spec-x').trim() };
    })()`);
    results.push((lens.index === '2' && lens.left > lens.navLeft ? 'PASS ' : 'FAIL ') +
      '底栏镜片胶囊跟随当前页滑动' + (lens.index === '2' ? '' : '（实际 --nav-index=' + lens.index + '）'));
    results.push(((liquid.skew !== '0deg' && liquid.skew !== '') || parseFloat(liquid.stretch) !== 1 ? 'PASS ' : 'FAIL ') +
      '底栏玻璃在滚动时产生形变' + (liquid.skew !== '0deg' ? '' : '（实际 skew=' + liquid.skew + ' stretch=' + liquid.stretch + '）'));
  } catch (error) {
    results.push('FAIL ' + error.message);
  } finally {
    if (cdp) cdp.close();
    // Edge headless 会派生子进程，只 kill 父进程会留下整棵树占着 profile 目录；
    // Windows 上用 taskkill /T 连子进程一起收掉，否则 profile 删不掉、越积越多。
    if (process.platform === 'win32') {
      try { spawnSync('taskkill', ['/PID', String(browser.pid), '/T', '/F'], { stdio: 'ignore' }); } catch (_) {}
    }
    browser.kill();
    server.close();
    serverBad.close();
    serverUnknown.close();
    // Edge 可能把启动参数交给已存在的浏览器进程后自己立刻退出（此时 browser.pid 已失效），
    // 所以再按 profile 目录名反查命令行，把真正持有该 profile 的 headless 进程收掉。
    if (process.platform === 'win32') {
      const tag = path.basename(profile);
      const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      const script = "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('" + tag + "') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }";
      try { spawnSync(ps, ['-NoProfile', '-NonInteractive', '-Command', script], { stdio: 'ignore', windowsHide: true }); } catch (_) {}
    }
    await sleep(900);
    await new Promise(resolve => {
      if (browser.exitCode !== null) return resolve();
      browser.once('exit', resolve);
      setTimeout(resolve, 4000);
    });
    await sleep(600);
    for (let i = 0; i < 10; i++) {
      try { fs.rmSync(profile, { recursive: true, force: true }); break; }
      catch (_) { await sleep(500); }
    }
  }
  fs.writeFileSync(path.join(OUT, 'render-result.txt'), results.join('\n') + '\n');
  console.log(results.join('\n'));
  process.exit(results.some(r => r.startsWith('FAIL')) ? 1 : 0);
})();
