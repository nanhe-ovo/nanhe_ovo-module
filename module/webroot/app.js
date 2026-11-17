(function () {
  'use strict';
  const C = window.NanheCore;
  const $ = id => document.getElementById(id);
  // 已知模式的展示文案；未知但存在于 uperf.json 的模式按原样显示。
  const MODE_META = {
    powersave: ['省电', '轻负载长续航'],
    balance: ['均衡', '日常刚刚好'],
    performance: ['性能', '流畅优先'],
    fast: ['极速', '高负载场景'],
    crazy: ['超频', '表内最高频+极限调度'],
  };
  // 静态内联 SVG，不随外部数据变化。
  const ICONS = {
    powersave: '<rect x="3" y="8" width="14" height="8.5" rx="2.6"/><path d="M20.4 11v2.5"/>',
    balance: '<path d="M3.5 8.5h17"/><path d="M3.5 15.5h17"/><circle cx="9" cy="8.5" r="2.1"/><circle cx="15" cy="15.5" r="2.1"/>',
    performance: '<path d="M13 3l-7 10h5l-2 8 7-10h-5z"/>',
    fast: '<path d="M6 18L18 6"/><path d="M10 6h8v8"/>',
    crazy: '<path d="M13 2L4.5 13.5H11L9.5 22 19 10h-6.5z"/>',
    default: '<path d="M12 4l7 8-7 8-7-8z"/>',
  };
  const SVG_HEAD = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">';
  const TITLES = { overview: '设备总览', frequency: '频率与显示', apps: '应用调度策略', about: '关于' };
  const NAV_ORDER = { overview: 0, frequency: 1, apps: 2, about: 3 };
  const SECTION_TITLES = {
    device: '设备信息', system: '系统信息', hardware: '硬件',
    memory: '内存 RAM', storage: '内部存储', screen: '屏幕', battery: '电池',
  };
  const DEMO = [
    'info\tboot_id\tdemo-boot',
    'info\tbaseline\t可用',
    'info\tconfig\t/sdcard/Android/yc/uperf/uperf.json',
    'info\tversion\tv1.2.1',
    'info\tdevice_config\ttemplate',
    'info\ttune\t开启',
    'info\tmode\tbalance',
    'info\tmodes\tpowersave balance performance fast crazy',
    'info\tuperf\t未运行',
    'info\trefresh\t120',
    'info\trefresh_target\t120',
    'info\trefresh_pin\toff',
    'info\trefresh_tiers\t30 48 60 72 90 120 144 165 180 240',
    'info\trefresh_supported\t60 90 120 144',
    'info\trefresh_known\t1',
    'device\tcpu-policy0\tCPU 策略 0\tkHz\t300000\t1800000\t1200000\t300000 600000 1200000 1800000',
    'device\tcpu-policy4\tCPU 策略 4\tkHz\t710400\t2800000\t1800000\t710400 1200000 1800000 2400000 2800000',
    'device\tgpu-0\tGPU 0（kgsl-3d0）\tHz\t200000000\t800000000\t400000000\t200000000 400000000 600000000 800000000',
  ].join('\n');
  const DEMO_RULES = '* balance\n- powersave\ncom.example.game performance';
  // 演示用的日志样例：结构与后端 logs 输出一致（log / 时间 / 级别 / 标签 / 正文）。
  const DEMO_LOGS = [
    ['2026-11-16 00:21:08', 'info', 'refresh', '已应用 120Hz（下限额on）'],
    ['2026-11-16 00:21:20', 'warn', 'refresh', '未读到刷新率档位表：dumpsys display 与 SurfaceFlinger 都没有给出可用档位，已放开全部档位供尝试'],
    ['2026-11-16 00:21:26', 'error', 'freq', 'cpu-policy6: maximum is not in frequency table'],
  ].map(([time, level, tag, message]) => ({ time, level, tag, message }));
  const state = {
    live: false, demo: true, busy: false, confirming: false,
    status: C.parseStatus(DEMO), apps: ['com.android.settings', 'com.example.reader', 'com.example.game'],
    rules: C.parseRules(DEMO_RULES), deviceInfo: [], logs: DEMO_LOGS.slice(), limit: 60,
    logged: Object.create(null),
  };

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function notice(text, error) { $('notice-text').textContent = text; $('notice').classList.toggle('error', !!error); $('notice').hidden = false; }
  function setBusy(value) {
    state.busy = value;
    document.body.classList.toggle('busy', value);
    $('refresh').disabled = value || state.confirming;
    $('tune-switch').disabled = value || state.confirming || !state.live;
    $('pin-switch').disabled = value || state.confirming || !state.live || !canPin();
    document.querySelectorAll('[data-write]').forEach(n => {
      n.disabled = value || state.confirming || !state.live || n.dataset.unavailable === 'true';
    });
  }
  function connection(text) { $('connection-text').textContent = text; $('connection').classList.toggle('live', state.live); }
  function modeList() { return state.status.modes.length ? state.status.modes : C.FALLBACK_MODES; }
  function meta(mode) { return MODE_META[mode] || [mode, 'uperf 自定义预设']; }
  function modeName(mode) { return mode ? meta(mode)[0] : '未设置'; }
  function currentMode() { const info = state.status.info; return info.mode || ''; }
  function tuneOn() { return state.status.info.tune === '开启'; }

  function demo() {
    state.live = false; state.demo = true;
    state.status = C.parseStatus(DEMO);
    state.apps = ['com.android.settings', 'com.example.reader', 'com.example.game'];
    state.rules = C.parseRules(DEMO_RULES);
    state.deviceInfo = [];
    state.logs = DEMO_LOGS.slice();
    state.logged = Object.create(null);
  }

  // 页面发现的问题自动写进后端日志；同一次会话里同一个 key 只写一条，
  // 避免每次轮询都重复。写不进去（无 Root / 桥接缺失）就静默跳过。
  function autoLog(key, level, tag, message) {
    if (!state.live || state.logged[key]) return;
    state.logged[key] = true;
    C.exec(window, C.command('logline', [level, tag, message])).catch(() => {});
  }

  async function loadLogs() {
    if (!state.live) { renderLogs(); return; }
    try {
      const result = await C.exec(window, C.command('logs'));
      state.logs = C.parseLogs(result.stdout);
    } catch (error) {
      state.logs = [{ time: new Date().toLocaleTimeString('zh-CN', { hour12: false }), level: 'error', tag: 'logs', message: '日志读取失败：' + error.message }];
    }
    renderLogs();
  }

  async function readBackend() {
    const root = await C.exec(window, 'id -u');
    if (root.stdout.trim() !== '0') throw new Error('未获得 Root 权限（uid 不是 0）');
    // status 是判定「设备是否可识别」的唯一硬条件；应用清单与规则只影响列表内容，
    // 它们失败时必须保留设备状态，而不是把整页退回演示模式。
    const status = await C.exec(window, C.command('status'));
    if (!status.stdout.trim()) throw new Error('后端未返回状态，无法确认设备能力');
    const parsed = C.parseStatus(status.stdout);
    if (!Object.keys(parsed.info).length && !parsed.devices.length) throw new Error('后端状态格式不匹配');
    state.status = parsed;
    const warnings = status.stderr.trim() ? [status.stderr.trim()] : [];

    let apps = null, rules = null;
    try { apps = await C.exec(window, C.command('apps')); }
    catch (error) { warnings.push('应用清单读取失败：' + error.message); }
    try { rules = await C.exec(window, C.command('rules')); }
    catch (error) { warnings.push('分应用规则读取失败：' + error.message); }
    if (apps) { state.apps = C.parseApps(apps.stdout); if (apps.stderr.trim()) warnings.push(apps.stderr.trim()); }
    else state.apps = [];
    if (rules) { state.rules = C.parseRules(rules.stdout); if (rules.stderr.trim()) warnings.push(rules.stderr.trim()); }
    else state.rules = Object.create(null);

    let devinfo = null;
    try { devinfo = await C.exec(window, C.command('deviceinfo')); }
    catch (error) { warnings.push('机型信息读取失败：' + error.message); }
    state.deviceInfo = devinfo ? C.parseDeviceInfo(devinfo.stdout) : [];

    state.live = true; state.demo = false;
    const rInfo = refreshInfo();
    if (!rInfo.known) autoLog('refresh-table', 'warn', 'refresh', '页面发现本机没有上报刷新率档位表，已放开全部档位（后端 status 的 refresh_known=0）');
    if (!state.apps.length) autoLog('apps-empty', 'warn', 'apps', '页面读到的应用列表为空（后端枚举失败或没有已安装应用）');
    if (!state.deviceInfo.length) autoLog('deviceinfo-empty', 'warn', 'deviceinfo', '页面没有读到机型与系统信息，关于页只显示版本');
    if (warnings.length) autoLog('read-warnings', 'warn', 'control', warnings.join(' / '));
    await loadLogs();
    if (warnings.length) notice('后端提示：\n' + warnings.join('\n'), false);
    connection('Root 已连接 · 本地 callback 桥接');
    $('last-update').textContent = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  }

  async function refresh() {
    if (state.busy || state.confirming) return;
    setBusy(true); connection('正在读取设备状态…');
    try { await readBackend(); }
    catch (error) {
      demo(); connection('只读演示 · 未连接真实设备');
      notice('无法读取真实设备，已进入只读演示，演示值不代表当前设备。\n' + error.message, true);
      $('last-update').textContent = '只读演示数据';
    }
    finally { render(); setBusy(false); }
  }

  function confirmAction(title, message) {
    return new Promise(resolve => {
      const dialog = $('confirm-dialog');
      $('confirm-title').textContent = title;
      $('confirm-message').textContent = message;
      dialog.returnValue = 'cancel';
      dialog.addEventListener('close', () => resolve(dialog.returnValue === 'confirm'), { once: true });
      if (typeof dialog.showModal === 'function') dialog.showModal();
      else { notice('当前 WebView 不支持安全确认对话框，已阻止写入。请更新管理器。', true); resolve(false); }
    });
  }

  async function mutate(title, description, action, args) {
    if (!state.live || state.busy || state.confirming) return;
    state.confirming = true; setBusy(false);
    let accepted = false;
    try { accepted = await confirmAction(title, description); }
    finally { state.confirming = false; setBusy(false); }
    if (!accepted) return;
    setBusy(true);
    let succeeded = false;
    try {
      const result = await C.exec(window, C.command(action, args));
      succeeded = true;
      await readBackend();
      notice((action === 'tune' ? '开关已保存，重启后生效。' : '后端已执行，状态已重新读取。') + (result.stderr.trim() ? '\n后端提示：' + result.stderr.trim() : ''), false);
    } catch (error) {
      state.logSeq = (state.logSeq || 0) + 1;
      autoLog('action-fail-' + state.logSeq, 'error', action, '页面执行 ' + action + ' 失败：' + String(error.message).replace(/\n/g, ' / '));
      notice((succeeded ? '命令已返回成功，但状态刷新失败；请刷新核实，勿重复提交。\n' : '操作未确认成功，请检查后端状态。\n') + error.message, true);
      // 结果未知时暂停写入，直到下一次成功刷新。
      state.live = false;
      connection('写入已暂停 · 请刷新核实真实状态');
    } finally { render(); setBusy(false); }
  }

  function refreshInfo() {
    const info = state.status.info;
    const tiers = C.numbers(info.refresh_tiers);
    const supported = C.numbers(info.refresh_supported).filter(hz => !tiers.length || tiers.includes(hz));
    const current = Number(info.refresh) > 0 ? Number(info.refresh) : null;
    const target = Number(info.refresh_target) > 0 ? Number(info.refresh_target) : null;
    // 后端读不到档位表时会放开全部档位（refresh_known=0），此时不能把界面整块禁用。
    const known = info.refresh_known !== '0';
    return { tiers, supported, current, target, known, pin: info.refresh_pin === 'on' };
  }
  function canPin() {
    const r = refreshInfo();
    return !!r.target && r.supported.length > 0;
  }

  function renderRefresh() {
    const r = refreshInfo();
    $('refresh-current').textContent = r.current ? r.current + ' Hz' : '—';
    const holder = $('refresh-tiers');
    holder.replaceChildren();
    r.tiers.forEach(hz => {
      const ok = r.supported.includes(hz);
      const chip = el('button', 'tier-chip' + (r.target === hz ? ' active' : ''), hz + 'Hz');
      chip.type = 'button';
      chip.dataset.write = '';
      chip.dataset.unavailable = String(!ok);
      chip.setAttribute('aria-pressed', String(r.target === hz));
      if (!ok) {
        chip.classList.add('unsupported');
        chip.setAttribute('aria-disabled', 'true');
        chip.title = '本机不支持该档位，已禁止选择';
      }
      chip.addEventListener('click', () => {
        if (!ok) { notice('本机不支持 ' + hz + 'Hz，已禁止选择。', true); return; }
        mutate('设置屏幕刷新率为 ' + hz + 'Hz？',
          '将写入系统刷新率' + (r.pin ? '上限与下限（强制取消静止降频）' : '上限') +
          '，并记录该目标，开机会自动重新应用。', 'refresh', [hz, r.pin ? 'on' : 'off']);
      });
      holder.append(chip);
    });
    if (!r.tiers.length) holder.append(el('p', 'empty', '后端没有报告刷新率档位。'));
    $('pin-switch').setAttribute('aria-checked', String(r.pin));
    $('pin-switch').disabled = state.busy || state.confirming || !state.live || !canPin();
    let note;
    if (!state.live) note = '只读演示：不会写入任何刷新率设置。';
    else if (!r.known) note = '本机没有上报可用的刷新率档位表，已放开全部档位供你尝试；系统不接受时会保持原值，可在关于页核对当前刷新率。';
    else if (!r.supported.length) note = '本机上报的档位与 30–240Hz 的常用档位没有交集，刷新率调节不可用。';
    else if (r.target) note = '已记录目标 ' + r.target + 'Hz，开机由模块重新应用' + (r.pin ? '，并钉住下限。' : '。');
    else note = '尚未设置目标；开机默认取本机最高档 ' + Math.max(...r.supported) + 'Hz，可在上方修改。';
    $('refresh-note').textContent = note;
  }

  function renderDeviceInfo() {
    const holder = $('device-info');
    holder.replaceChildren();
    if (!state.deviceInfo.length) {
      holder.append(el('p', 'empty', state.live ? '未能读取机型信息。' : '只读演示中没有机型信息。'));
      return;
    }
    const groups = new Map();
    state.deviceInfo.forEach(row => {
      if (!groups.has(row.section)) groups.set(row.section, []);
      groups.get(row.section).push(row);
    });
    const order = Object.keys(SECTION_TITLES);
    const keys = order.filter(k => groups.has(k)).concat([...groups.keys()].filter(k => !order.includes(k)));
    keys.forEach(key => {
      const card = el('article', 'card info-card');
      card.append(el('h2', '', SECTION_TITLES[key] || key));
      const dl = el('dl', 'details');
      groups.get(key).forEach(row => {
        const line = el('div');
        line.append(el('dt', '', row.label), el('dd', '', row.value));
        dl.append(line);
      });
      card.append(dl);
      holder.append(card);
    });
  }

  function renderModes() {
    const grid = $('mode-grid');
    grid.replaceChildren();
    const modes = modeList();
    grid.style.gridTemplateColumns = 'repeat(' + Math.min(modes.length || 1, 4) + ',minmax(0,1fr))';
    modes.forEach(mode => {
      const info = meta(mode);
      const active = currentMode() === mode;
      const button = el('button', 'mode-button' + (active ? ' active' : ''));
      button.type = 'button';
      button.dataset.write = '';
      button.setAttribute('aria-pressed', String(active));
      const icon = el('span', 'mode-icon');
      icon.innerHTML = SVG_HEAD + (ICONS[mode] || ICONS.default) + '</svg>';
      button.append(icon, el('span', 'mode-name', info[0]), el('span', 'mode-desc', info[1]));
      button.addEventListener('click', () => {
        const extra = mode === 'crazy'
          ? '\n\n超频模式会把可写的 CPU 集群上限推到频率表最高档（表内最高，不超出厂上限，仍受内核/温控限制）；离开该模式会自动恢复本次开机的频率基线。'
          : '';
        mutate('切换为' + info[0] + '模式？', '将立即调用后端设置全局模式：' + mode + '。' + extra, 'mode', [mode]);
      });
      grid.append(button);
    });
    if (!modes.length) grid.append(el('p', 'empty', '后端没有报告可用的性能模式，请检查 uperf.json。'));
    $('mode-badge').textContent = (state.demo ? '演示 · ' : state.live ? '当前 · ' : '上次读取 · ') + modeName(currentMode());
    $('tune-switch').setAttribute('aria-checked', String(tuneOn()));
  }

  function renderSummary() {
    const holder = $('device-summary');
    holder.replaceChildren();
    state.status.devices.forEach(device => {
      const card = el('article', 'card summary-card');
      const cpu = device.id.startsWith('cpu-');
      card.append(el('span', 'device-tag', cpu ? 'CPU' : 'GPU'), el('h3', '', device.label));
      const value = el('div', 'frequency-value', C.mhz(device.current, device.unit).replace(' MHz', ''));
      value.append(el('small', '', 'MHz'));
      const meter = el('div', 'mini-meter');
      const fill = el('span');
      fill.style.width = Math.min(100, device.max > 0 ? device.current / device.max * 100 : 0) + '%';
      meter.append(fill);
      card.append(value, meter);
      holder.append(card);
    });
    if (!state.status.devices.length) holder.append(el('p', 'empty', '后端没有报告可用的 CPU / GPU 频率节点。'));

    const info = $('system-info');
    info.replaceChildren();
    const names = {
      device_config: '平台配置', version: '模块版本', mode: '当前模式', modes: '可用模式',
      uperf: '调度引擎', tune: '系统调优', baseline: '频率基线', config: '配置文件',
      boot_id: '启动批次', service: '服务状态', backend: '后端', susfs: 'SUSFS 状态', root: 'Root 方案',
    };
    const order = ['root', 'mode', 'version', 'uperf', 'susfs', 'baseline', 'tune', 'device_config'];
    Object.entries(state.status.info)
      .filter(([key]) => order.indexOf(key) >= 0)
      .sort((a, b) => (order.indexOf(a[0]) + 1 || 99) - (order.indexOf(b[0]) + 1 || 99))
      .forEach(([key, value]) => {
        const row = el('div', 'kv');
        let text = value;
        if (key === 'mode') text = modeName(value);
        if (key === 'modes') text = state.status.modes.map(modeName).join(' · ') || '未报告';
        row.append(el('span', 'k', names[key] || key), el('span', 'v', text));
        info.append(row);
      });
    if (!Object.keys(state.status.info).length) info.append(el('p', 'muted', '后端未提供附加信息'));
  }

  function frequencySelect(device, selected, labelText) {
    const label = el('label', '', labelText);
    const select = el('select');
    select.dataset.write = '';
    select.setAttribute('aria-label', device.label + labelText);
    device.frequencies.forEach(value => {
      const option = el('option', '', C.mhz(value, device.unit));
      option.value = String(value);
      select.append(option);
    });
    if (device.frequencies.includes(selected)) select.value = String(selected);
    else {
      const option = el('option', '', '请选择表内频率');
      option.value = '';
      option.disabled = true; option.selected = true;
      select.prepend(option);
    }
    if (!device.frequencies.length) select.dataset.unavailable = 'true';
    label.append(select);
    return { label, select };
  }

  function renderFrequencies() {
    const holder = $('frequency-list');
    holder.replaceChildren();
    state.status.devices.forEach(device => {
      const card = el('article', 'card');
      const header = el('div', 'frequency-header');
      const text = el('div');
      text.append(el('h2', '', device.label), el('p', '', device.id + ' · 原始单位 ' + device.unit));
      const current = el('div', 'current-value', C.mhz(device.current, device.unit));
      current.append(el('small', '', '当前频率'));
      header.append(text, current);
      card.append(header);
      const min = frequencySelect(device, device.min, '最低频率');
      const max = frequencySelect(device, device.max, '最高频率');
      const fields = el('div', 'range-fields');
      fields.append(min.label, max.label);
      card.append(fields);
      card.append(el('p', 'list-note', '当前范围 ' + C.mhz(device.min, device.unit) + ' – ' + C.mhz(device.max, device.unit)));
      if (!device.frequencies.length) card.append(el('p', 'device-warning', '没有可用频率表，禁止写入。'));
      else if (!device.frequencies.includes(device.min) || !device.frequencies.includes(device.max)) card.append(el('p', 'device-warning', '当前边界不在频率表中，请重新选择两个边界。'));
      const button = el('button', 'primary-button apply-button', '应用频率区间');
      button.type = 'button';
      button.dataset.write = '';
      if (!device.frequencies.length) button.dataset.unavailable = 'true';
      button.addEventListener('click', () => {
        try {
          const range = C.validateRange(device, min.select.value, max.select.value);
          mutate('应用频率区间？', device.label + '\n' + C.mhz(range[0], device.unit) + ' – ' + C.mhz(range[1], device.unit) +
            '\n原始值：' + range.join(' – ') + ' ' + device.unit + '\n仅即时生效，不设置开机持久化。', 'freq', [device.id].concat(range));
        } catch (error) { notice(error.message, true); }
      });
      card.append(button);
      holder.append(card);
    });
    if (!state.status.devices.length) holder.append(el('p', 'empty', '没有可管理的频率节点。'));
  }

  function ruleRow(pkg) {
    const special = pkg === '*' || pkg === '-';
    const row = el('div', 'rule-row');
    const heading = el('div', 'rule-title');
    const text = el('div');
    text.append(
      el('strong', '', pkg === '*' ? '默认规则 *' : pkg === '-' ? '熄屏规则 -' : pkg),
      el('small', '', '当前：' + (state.rules[pkg] ? modeName(state.rules[pkg]) : '未设置（跟随默认）'))
    );
    heading.append(el('span', 'app-avatar', special ? pkg : pkg.split('.').pop().slice(0, 1).toUpperCase()), text);
    row.append(heading);
    const controls = el('div', 'rule-controls');
    const select = el('select');
    select.dataset.write = '';
    select.setAttribute('aria-label', pkg + ' 调度策略');
    const modes = modeList();
    modes.forEach(mode => {
      const option = el('option', '', modeName(mode));
      option.value = mode;
      select.append(option);
    });
    select.value = modes.includes(state.rules[pkg]) ? state.rules[pkg] : (modes.includes('balance') ? 'balance' : modes[0] || '');
    const save = el('button', 'primary-button', '保存');
    save.type = 'button'; save.dataset.write = '';
    save.addEventListener('click', () => {
      if (!select.value) { notice('当前没有可用的性能模式，无法保存规则。', true); return; }
      mutate('保存应用策略？', pkg + '\n设置为「' + modeName(select.value) + '」模式。', 'rule', [pkg, select.value]);
    });
    const remove = el('button', 'secondary-button', '删除');
    remove.type = 'button'; remove.dataset.write = '';
    remove.dataset.unavailable = String(!state.rules[pkg]);
    remove.setAttribute('aria-label', '删除 ' + pkg + ' 的策略');
    remove.addEventListener('click', () => mutate('删除策略？', '将删除 ' + pkg + ' 的显式规则。' +
      (special ? '\n这是特殊规则，删除后由 uperf 默认行为处理。' : '\n该应用将按默认规则处理。'), 'rule', [pkg, 'delete']));
    controls.append(select, save, remove);
    row.append(controls);
    return row;
  }

  function renderApps() {
    const special = $('special-rules');
    special.replaceChildren(ruleRow('*'), ruleRow('-'));
    const query = $('app-search').value.trim().toLowerCase();
    const packages = [...new Set(state.apps.concat(Object.keys(state.rules).filter(p => p !== '*' && p !== '-')))]
      .sort().filter(p => p.toLowerCase().includes(query));
    $('app-count').textContent = packages.length + ' 个包' + (state.demo ? ' · 演示' : state.live ? '' : ' · 上次读取');
    const list = $('app-list');
    list.replaceChildren();
    packages.slice(0, state.limit).forEach(pkg => list.append(ruleRow(pkg)));
    if (!packages.length) list.append(el('p', 'empty', query ? '未找到匹配的包名' :
      (state.live ? '本机未能枚举到应用包名。设备状态仍可正常读写，可在终端执行 pm list packages 排查枚举失败的原因。' : '未读取到已安装应用或应用规则')));
    if (packages.length > state.limit) {
      const more = el('button', 'text-button', '再显示 60 个（剩余 ' + (packages.length - state.limit) + '）');
      more.type = 'button';
      more.addEventListener('click', () => { state.limit += 60; renderApps(); setBusy(state.busy); });
      list.append(more);
    }
  }

  function renderAbout() {
    const info = state.status.info;
    $('about-version').textContent = info.version || 'v-';
  }

  // 运行日志：新的在上面；只显示最近 60 条，完整内容仍保留在后端文件里。
  function renderLogs() {
    const list = $('log-list');
    list.replaceChildren();
    $('log-count').textContent = state.logs.length + ' 条' + (state.demo ? ' · 演示' : '');
    const rows = state.logs.slice().reverse().slice(0, 60);
    rows.forEach(row => {
      const li = el('li', 'log-row ' + row.level);
      const head = el('div', 'log-meta');
      head.append(
        el('span', 'log-time', String(row.time).replace(/^\d{4}-\d{2}-\d{2} /, '')),
        el('span', 'log-level', row.level === 'error' ? '异常' : row.level === 'warn' ? '注意' : '记录'),
        el('span', 'log-tag', row.tag)
      );
      li.append(head, el('p', 'log-message', row.message));
      list.append(li);
    });
    if (!rows.length) list.append(el('li', 'empty', state.live ? '还没有日志。后端命令失败或发现异常时会自动记录在这里。' : '只读演示：日志来自演示数据。'));
    $('log-reload').disabled = !state.live;
    $('log-clear').disabled = !state.live;
  }
  /* 首页状态卡：仿 SukiSU 的绿色「工作中」大卡，状态只由后端 info 驱动，不做假成功 */
  function renderStatus() {
    const card = $('status-card');
    if (!card) return;
    const info = state.status.info || {};
    const running = state.live && String(info.uperf || '').indexOf('运行') >= 0;
    const kind = state.demo ? 'demo' : running ? 'run' : 'idle';
    card.dataset.state = kind;
    const rootMode = String(info.root || '');
    const rootShort = rootMode.indexOf('LKM') >= 0 ? 'LKM' : rootMode.indexOf('GKI') >= 0 ? 'GKI'
      : rootMode.indexOf('APatch') >= 0 ? 'APatch' : rootMode.indexOf('Magisk') >= 0 ? 'Magisk' : '';
    $('status-tag').textContent = kind === 'demo' ? '演示' : kind === 'idle' ? '待机' : (rootShort || 'Root');
    $('overview-heading').textContent = kind === 'run' ? '工作中' : kind === 'demo' ? '只读演示' : '待机';
    $('status-version').textContent = info.version || 'v-';
    $('status-root').textContent = info.root || (state.live ? '未读到' : '未知');
    $('stat-rules').textContent = String(Object.keys(state.rules || {}).length);
    $('stat-devices').textContent = String((state.status.devices || []).length);
  }
  function render() { renderStatus(); renderModes(); renderSummary(); renderFrequencies(); renderRefresh(); renderApps(); renderAbout(); renderLogs(); renderDeviceInfo(); }

  function navigate() {
    const page = Object.prototype.hasOwnProperty.call(TITLES, location.hash.slice(1)) ? location.hash.slice(1) : 'overview';
    Object.keys(TITLES).forEach(key => { $('page-' + key).hidden = key !== page; });
    document.querySelectorAll('[data-page]').forEach(a => {
      if (a.dataset.page === page) a.setAttribute('aria-current', 'page');
      else a.removeAttribute('aria-current');
    });
    $('page-title').textContent = TITLES[page];
    document.title = TITLES[page] + ' · 性能调度';
    const nav = document.querySelector('.bottom-nav');
    if (nav && NAV_ORDER[page] !== undefined) nav.style.setProperty('--nav-index', NAV_ORDER[page]);
  }

  let theme;
  try { theme = localStorage.getItem('nanhe-theme'); } catch (_) { /* WebView 可能禁止存储 */ }
  if (!['light', 'dark'].includes(theme)) theme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  function applyTheme() {
    document.documentElement.dataset.theme = theme;
    $('theme-toggle').setAttribute('aria-label', theme === 'dark' ? '切换浅色主题' : '切换深色主题');
  }
  applyTheme();
  $('theme-toggle').addEventListener('click', () => {
    theme = theme === 'dark' ? 'light' : 'dark';
    applyTheme();
    try { localStorage.setItem('nanhe-theme', theme); } catch (_) {}
  });
  $('refresh').addEventListener('click', refresh);
  $('log-reload').addEventListener('click', () => { loadLogs(); });
  $('log-clear').addEventListener('click', () => {
    if (!state.live || state.busy || state.confirming) return;
    mutate('清空运行日志？', '将删除模块目录下的日志文件；之后的异常仍会自动重新记录。', 'clearlog', []);
  });
  $('dismiss-notice').addEventListener('click', () => { $('notice').hidden = true; });
  $('restore').addEventListener('click', () => mutate('恢复开机频率？', '将调用后端 restore 回到本次开机的原始频率边界。此操作会覆盖当前手动频率区间。', 'restore', []));
  $('tune-switch').addEventListener('click', () => {
    const next = !tuneOn();
    mutate(next ? '开启系统调优？' : '关闭系统调优？',
      next ? '开机会执行厂商调度压平与温控进程处理（uperf 上游行为），下次开机生效。' : '开机会跳过厂商调度压平与温控处理，只启动 uperf 引擎，下次开机生效。',
      'tune', [next ? 'on' : 'off']);
  });
  $('pin-switch').addEventListener('click', () => {
    const r = refreshInfo();
    if (!r.target) { notice('请先选择一个刷新率档位，再打开「强制取消静止降频」。', true); return; }
    mutate(r.pin ? '关闭强制取消静止降频？' : '开启强制取消静止降频？',
      '目标刷新率 ' + r.target + 'Hz\n' +
      (r.pin ? '将删除刷新率下限，系统可在静止时回落到较低档位。' : '将把下限也钉到 ' + r.target + 'Hz，画面静止时不再回落。') +
      '\n改动立即生效，并由开机脚本重新应用。',
      'refresh', [r.target, r.pin ? 'off' : 'on']);
  });
  $('app-search').addEventListener('input', () => { state.limit = 60; renderApps(); setBusy(state.busy); });

  // 玻璃的镜面高光跟随指针，按下时轻微收缩再回弹：这是 Backdrop 交互玻璃的核心手感
  const GLASS_SURFACE = '.card, .bottom-nav, .mode-button, .switch-row, .app-list, .search-field, .tier-chip';
  const PRESSABLE = '.card, .mode-button, .switch-row, .app-list, .search-field, .tier-chip, .notice, .soft-note';
  document.addEventListener('pointermove', ev => {
    const surface = ev.target.closest ? ev.target.closest(GLASS_SURFACE) : null;
    if (!surface) return;
    const box = surface.getBoundingClientRect();
    if (!box.width || !box.height) return;
    surface.style.setProperty('--spec-x', ((ev.clientX - box.left) / box.width * 100).toFixed(1) + '%');
    surface.style.setProperty('--spec-y', ((ev.clientY - box.top) / box.height * 100).toFixed(1) + '%');
  }, { passive: true });
  document.addEventListener('pointerdown', ev => {
    const target = ev.target.closest ? ev.target.closest(PRESSABLE) : null;
    if (target) target.classList.add('pressing');
  }, true);
  const release = ev => {
    const target = ev.target.closest ? ev.target.closest(PRESSABLE) : null;
    if (target) target.classList.remove('pressing');
    document.querySelectorAll('.pressing').forEach(node => node.classList.remove('pressing'));
  };
  document.addEventListener('pointerup', release, true);
  document.addEventListener('pointercancel', release, true);

  // 底栏液态玻璃的滑动反馈：页面滚动带起玻璃的轻微倾斜/拉伸，停下后用弹簧曲线回位（照 Backdrop 的 lens 手感）
  const nav = document.querySelector('.bottom-nav');
  let navVel = 0, navTarget = 0, navRaf = 0, navLast = window.scrollY || 0, navTickAt = 0;
  function navSettle() {
    if (!nav) return;
    nav.style.setProperty('--nav-skew', '0deg');
    nav.style.setProperty('--nav-stretch', '1');
    nav.style.setProperty('--nav-drop', '0px');
    nav.style.setProperty('--spec-x', '50%');
  }
  function navTick(now) {
    const dt = navTickAt ? Math.max(8, now - navTickAt) : 16;
    navTickAt = now;
    navTarget *= 0.88;
    navVel += (navTarget - navVel) * Math.min(1, dt / 80);
    const lean = Math.max(-1, Math.min(1, navVel / 24));
    if (nav) {
      nav.style.setProperty('--nav-skew', (lean * 1.8).toFixed(2) + 'deg');
      nav.style.setProperty('--nav-stretch', (1 - Math.abs(lean) * 0.016).toFixed(3));
      nav.style.setProperty('--nav-drop', (Math.abs(lean) * 3.2).toFixed(1) + 'px');
      nav.style.setProperty('--spec-x', (50 - lean * 28).toFixed(1) + '%');
    }
    if (Math.abs(navVel) > 0.35 || Math.abs(navTarget) > 0.35) navRaf = requestAnimationFrame(navTick);
    else { navRaf = 0; navTickAt = 0; navSettle(); }
  }
  window.addEventListener('scroll', () => {
    const y = window.scrollY;
    navTarget = navTarget * 0.72 + (y - navLast) * 0.9;
    navLast = y;
    if (!navRaf) navRaf = requestAnimationFrame(navTick);
  }, { passive: true });

  window.addEventListener('hashchange', navigate);
  navigate(); render(); setBusy(false); refresh();
})();
