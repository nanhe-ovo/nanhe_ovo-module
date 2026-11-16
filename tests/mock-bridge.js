/* 仅用于本地预览与自动测试的假桥接，不会随模块发布。 */
(function () {
  'use strict';
  const STATUS = [
    'info\tboot_id\tpreview-boot-0000',
    'info\tbaseline\t可用',
    'info\tconfig\t/sdcard/Android/yc/uperf/uperf.json',
    'info\tversion\tv1.3.1',
    'info\tdevice_config\tsdm8g2',
    'info\ttune\t开启',
    'info\tmode\tbalance',
    'info\tmodes\tpowersave balance performance fast',
    'info\tuperf\t运行中',
    'info\trefresh\t120',
    'info\trefresh_target\t120',
    'info\trefresh_pin\toff',
    'info\trefresh_tiers\t30 48 60 72 90 120 144 165 180 240',
    'info\trefresh_supported\t60 120 144',
    'info\trefresh_known\t1',
    'info\tsusfs\t已加载',
    'info\troot\tKernelSU · LKM',
    'device\tcpu-policy0\tCPU 策略 0\tkHz\t307200\t1785600\t1017600\t307200 576000 1017600 1478400 1785600',
    'device\tcpu-policy4\tCPU 策略 4\tkHz\t710400\t2035200\t1478400\t710400 1286400 1478400 1804800 2035200',
    'device\tcpu-policy7\tCPU 策略 7\tkHz\t844800\t2803200\t1996800\t844800 1286400 1996800 2419200 2803200',
    'device\tgpu-0\tGPU 0（kgsl-3d0）\tHz\t220000000\t903000000\t578000000\t220000000 525000000 578000000 719000000 903000000',
  ].join('\n');
  // 模拟真机读不到档位表：后端会放开全部档位，面板不能整块禁用。
  const STATUS_UNKNOWN = STATUS
    .replace('info\trefresh_supported\t60 120 144', 'info\trefresh_supported\t30 48 60 72 90 120 144 165 180 240')
    .replace('info\trefresh_known\t1', 'info\trefresh_known\t0');
  const APPS = ['com.android.settings', 'com.tencent.mm', 'com.example.reader', 'com.example.game', 'com.miHoYo.Yuanshen', 'org.telegram.messenger'].join('\n');
  const RULES = '# 分应用性能模式配置\n# \'-\' means offscreen rule\n# \'*\' means default rule\n\ncom.miHoYo.Yuanshen performance\ncom.example.game fast\n- powersave\n* balance\n';
  const DEVINFO = [
    ['device', '品牌', 'REDMI'],
    ['device', '型号', '25079RPDCC'],
    ['device', '制造商', 'Xiaomi'],
    ['device', '设备代号', 'turner'],
    ['system', 'Android 版本', '17'],
    ['system', 'API 级别', '37'],
    ['system', '内核版本', '6.6.118-android15-preview'],
    ['hardware', '主架构', 'arm64-v8a'],
    ['hardware', '核心数', '8'],
    ['hardware', 'CPU 温度', '61.5 °C'],
    ['memory', '总内存', '11.24 GB'],
    ['storage', '总容量', '233.59 GB'],
    ['screen', '分辨率', '1880 × 3008 px'],
    ['screen', '当前刷新率', '120 Hz'],
    ['battery', '电量', '82%'],
    ['battery', '温度', '35.0 °C'],
  ].map(r => 'kv\t' + r.join('\t')).join('\n');

  const LOGS = [
    ['2026-11-16 00:21:08', 'info', 'refresh', '已应用 120Hz（下限额off）'],
    ['2026-11-16 00:21:20', 'warn', 'refresh', '未读到刷新率档位表：dumpsys display 与 SurfaceFlinger 都没有给出可用档位，已放开全部档位供尝试'],
    ['2026-11-16 00:21:26', 'error', 'freq', 'cpu-policy6: maximum is not in frequency table'],
  ].map(r => 'log\t' + r.join('\t'));
  if (!window.NANHE_MOCK_LOGS) window.NANHE_MOCK_LOGS = LOGS.slice();

  function reply(name, errno, out, err) {
    const cb = window[name];
    if (typeof cb !== 'function') return;
    setTimeout(() => cb(errno, out, err), 30);
  }
  window.ksu = {
    exec(command, options, name) {
      const cmd = String(command);
      if (cmd === 'id -u') return reply(name, 0, '0\n', '');
      if (cmd.indexOf('control.sh') === -1) return reply(name, 1, '', 'preview: 未知命令');
      const tail = cmd.replace(/'/g, '').split('control.sh')[1].trim();
      if (tail === 'status') return reply(name, 0, (window.NANHE_MOCK_REFRESH_UNKNOWN ? STATUS_UNKNOWN : STATUS) + '\nok\tstatus\n', '');
      if (tail === 'apps') {
        // 模拟真机：pm 枚举失败，用来验证面板不会因此退回演示模式
        if (window.NANHE_MOCK_FAIL_APPS) return reply(name, 1, '', 'control: pm list packages failed');
        return reply(name, 0, APPS + '\n', '');
      }
      if (tail === 'rules') {
        if (window.NANHE_MOCK_FAIL_APPS) return reply(name, 1, '', 'control: rules unreadable');
        return reply(name, 0, RULES, '');
      }
      if (tail === 'deviceinfo') return reply(name, 0, DEVINFO + '\nok\tdeviceinfo\n', '');
      if (tail === 'logs') return reply(name, 0, window.NANHE_MOCK_LOGS.concat(['ok\tlogs']).join('\n') + '\n', '');
      if (tail === 'clearlog') { window.NANHE_MOCK_LOGS = []; return reply(name, 0, 'ok\tclearlog\n', ''); }
      if (tail.indexOf('logline ') === 0) {
        const parts = tail.slice(8).split(/\s+/);
        const level = parts[0] || 'info', tag = parts[1] || 'page';
        const message = parts.slice(2).join(' ');
        const stamp = new Date().toISOString().slice(0, 19).replace('T', ' ');
        window.NANHE_MOCK_LOGS.push(['log', stamp, level, tag, message].join('\t'));
        return reply(name, 0, 'ok\tlogline\n', '');
      }
      return reply(name, 0, 'ok\tpreview\n', '');
    },
  };
})();
