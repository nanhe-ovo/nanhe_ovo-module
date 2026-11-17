/* 南何ovo — 独立实现的 KernelSU callback 桥接适配层（非 KernelSU 官方库）。 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.NanheCore = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const CONTROL = '/data/adb/modules/nanhe_ovo/script/control.sh';
  const FALLBACK_MODES = ['powersave', 'balance', 'performance', 'fast', 'crazy'];
  let sequence = 0;

  function quote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'"; }
  function validMode(value) { return typeof value === 'string' && value.length <= 24 && /^[a-z][a-z0-9_]*$/.test(value); }
  function validPackage(value) { return value === '*' || value === '-' || (typeof value === 'string' && /^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$/.test(value)); }

  function command(action, args) {
    args = args || [];
    const base = 'sh ' + quote(CONTROL) + ' ';
    if (['status', 'apps', 'rules', 'restore', 'deviceinfo', 'logs', 'clearlog'].includes(action) && args.length === 0) return base + action;
    if (action === 'logline' && args.length === 3) {
      if (!['info', 'warn', 'error'].includes(args[0])) throw new Error('拒绝无效的日志级别');
      if (!/^[a-z0-9_.-]{1,24}$/.test(String(args[1]))) throw new Error('拒绝无效的日志标签');
      const message = String(args[2] || '').replace(/[\r\n\t]/g, ' ').trim();
      if (!message) throw new Error('拒绝空的日志内容');
      return base + 'logline ' + quote(args[0]) + ' ' + quote(args[1]) + ' ' + quote(message.slice(0, 200));
    }
    if (action === 'mode' && args.length === 1) {
      if (!validMode(args[0])) throw new Error('拒绝无效的模式名');
      return base + 'mode ' + quote(args[0]);
    }
    if (action === 'tune' && args.length === 1) {
      if (!['on', 'off'].includes(args[0])) throw new Error('拒绝无效的调优参数');
      return base + 'tune ' + args[0];
    }
    if (action === 'rule' && args.length === 2) {
      if (!validPackage(args[0])) throw new Error('拒绝无效的包名');
      if (args[1] !== 'delete' && !validMode(args[1])) throw new Error('拒绝无效的模式名');
      return base + 'rule ' + args.map(quote).join(' ');
    }
    if (action === 'freq' && args.length === 3) {
      if (!/^(cpu-policy\d+|gpu-\d+)$/.test(args[0])) throw new Error('拒绝无效的节点标识');
      if (!args.slice(1).every(x => /^\d+$/.test(String(x)) && Number.isSafeInteger(Number(x)) && Number(x) > 0)) throw new Error('拒绝无效的频率值');
      if (Number(args[1]) > Number(args[2])) throw new Error('最低频率不能高于最高频率');
      return base + 'freq ' + args.map(quote).join(' ');
    }
    if (action === 'refresh' && args.length === 2) {
      const hz = Number(args[0]);
      if (!/^\d{2,3}$/.test(String(args[0])) || !Number.isSafeInteger(hz) || hz < 20 || hz > 300) throw new Error('拒绝无效的刷新率');
      if (!['on', 'off'].includes(args[1])) throw new Error('拒绝无效的刷新率锁定参数');
      return base + 'refresh ' + quote(String(hz)) + ' ' + args[1];
    }
    throw new Error('拒绝无效的控制参数');
  }

  // 原生签名：ksu.exec(command, JSON.stringify(options), callbackName)。
  function exec(host, cmd, timeoutMs) {
    return new Promise((resolve, reject) => {
      if (!host.ksu || typeof host.ksu.exec !== 'function') return reject(new Error('未发现兼容的 KernelSU callback 桥接'));
      const name = '__nanhe_exec_' + Date.now() + '_' + sequence++;
      let timer;
      const cleanup = () => { clearTimeout(timer); try { delete host[name]; } catch (_) { host[name] = undefined; } };
      host[name] = (errno, stdout, stderr) => {
        cleanup();
        const code = Number(errno);
        if (!Number.isFinite(code) || code !== 0) {
          const error = new Error('执行失败（退出码 ' + String(errno) + '）\n' + String(stderr || stdout || '后端未提供错误详情').trim());
          error.errno = errno;
          reject(error);
        } else resolve({ errno: code, stdout: String(stdout || ''), stderr: String(stderr || '') });
      };
      timer = setTimeout(() => { cleanup(); reject(new Error('桥接响应超时，执行结果未知。请刷新核实后再操作。')); }, timeoutMs || 25000);
      try { host.ksu.exec(cmd, JSON.stringify({}), name); }
      catch (error) { cleanup(); reject(error); }
    });
  }

  function parseStatus(text) {
    const info = Object.create(null), devices = [], seen = new Set();
    String(text).split(/\r?\n/).filter(Boolean).forEach(line => {
      const p = line.split('\t');
      if (p[0] === 'info' && p.length >= 2) info[p[1]] = p.slice(2).join('\t');
      if (p[0] !== 'device') return;
      const values = p.slice(4, 7).map(Number);
      const frequencies = (p[7] || '').trim().split(/\s+/).filter(Boolean).map(Number);
      if (p.length !== 8 || !/^(cpu-policy\d+|gpu-\d+)$/.test(p[1]) || !['kHz', 'Hz'].includes(p[3]) ||
          values.length !== 3 || values.some(n => !Number.isSafeInteger(n) || n < 0) || values[0] > values[1] ||
          frequencies.some(n => !Number.isSafeInteger(n) || n <= 0) || seen.has(p[1])) {
        throw new Error('后端返回了无效的设备频率数据');
      }
      seen.add(p[1]);
      devices.push({
        id: p[1], label: p[2], unit: p[3],
        min: values[0], max: values[1], current: values[2],
        frequencies: [...new Set(frequencies)].sort((a, b) => a - b),
      });
    });
    const modes = String(info.modes || '').trim().split(/\s+/).filter(m => validMode(m));
    return { info, devices, modes };
  }

  function parseRules(text) {
    const rules = Object.create(null);
    String(text).split(/\r?\n/).forEach(line => {
      const p = line.replace(/#.*/, '').trim().split(/\s+/);
      if (p.length === 2 && validPackage(p[0]) && validMode(p[1])) rules[p[0]] = p[1];
    });
    return rules;
  }

  function parseApps(text) {
    return [...new Set(String(text).split(/\r?\n/).map(s => s.trim()).filter(s => validPackage(s) && s !== '*' && s !== '-'))].sort();
  }

  // 机型信息：kv <section> <label> <value>，只做展示，字段名与顺序由后端决定。
  function parseDeviceInfo(text) {
    const rows = [];
    String(text).split(/\r?\n/).filter(Boolean).forEach(line => {
      const p = line.split('\t');
      if (p[0] !== 'kv' || p.length < 4) return;
      if (!/^[a-z]+$/.test(p[1]) || !p[2]) return;
      rows.push({ section: p[1], label: p[2], value: p.slice(3).join('\t') });
    });
    return rows;
  }

  // 运行日志：log <时间> <级别> <标签> <正文>，只做展示，级别统一成三种。
  function parseLogs(text) {
    const rows = [];
    String(text).split(/\r?\n/).filter(Boolean).forEach(line => {
      const p = line.split('\t');
      if (p[0] !== 'log' || p.length < 5) return;
      const level = ['info', 'warn', 'error'].includes(p[2]) ? p[2] : 'info';
      if (!p[1]) return;
      rows.push({ time: p[1], level, tag: p[3] || '-', message: p.slice(4).join('\t') });
    });
    return rows;
  }

  function numbers(text) {
    return String(text || '').trim().split(/\s+/).filter(Boolean)
      .map(Number).filter(n => Number.isSafeInteger(n) && n > 0);
  }

  function mhz(raw, unit) {
    return (Number(raw) / (unit === 'Hz' ? 1000000 : 1000)).toLocaleString('zh-CN', { maximumFractionDigits: 3 }) + ' MHz';
  }

  function validateRange(device, min, max) {
    if (!device.frequencies.includes(Number(min)) || !device.frequencies.includes(Number(max))) throw new Error('只能选择后端频率表中的值');
    if (Number(min) > Number(max)) throw new Error('最低频率不能高于最高频率');
    return [String(min), String(max)];
  }

  return { CONTROL, FALLBACK_MODES, command, exec, parseStatus, parseRules, parseApps, parseDeviceInfo, parseLogs, numbers, mhz, validateRange, validMode, validPackage };
});
