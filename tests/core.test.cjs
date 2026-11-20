/* core.js 单元测试：命令构造、参数拒绝、状态解析。 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const C = require(path.join(__dirname, '..', 'module', 'webroot', 'core.js'));
const plain = value => Object.fromEntries(Object.entries(value));

// 命令构造
assert.strictEqual(C.command('status'), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' status");
assert.strictEqual(C.command('restore'), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' restore");
assert.strictEqual(C.command('mode', ['fast']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' mode 'fast'");
assert.strictEqual(C.command('rule', ['com.example.game', 'performance']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' rule 'com.example.game' 'performance'");
assert.strictEqual(C.command('rule', ['*', 'delete']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' rule '*' 'delete'");
assert.strictEqual(C.command('tune', ['off']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' tune off");
assert.strictEqual(C.command('freq', ['cpu-policy0', '300000', '1800000']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' freq 'cpu-policy0' '300000' '1800000'");
assert.strictEqual(C.command('refresh', ['120', 'on']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' refresh '120' on");
assert.strictEqual(C.command('refresh', ['60', 'off']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' refresh '60' off");
assert.strictEqual(C.command('refresh_manage', ['on']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' refresh_manage on");
assert.strictEqual(C.command('refresh_manage', ['off']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' refresh_manage off");
assert.strictEqual(C.command('deviceinfo'), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' deviceinfo");
assert.strictEqual(C.command('thread', ['on']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' thread on");
assert.strictEqual(C.command('thread', ['off']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' thread off");
assert.strictEqual(C.command('threadrule', ['com.example.game', 'game']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' threadrule 'com.example.game' 'game'");
assert.strictEqual(C.command('threadrule', ['com.example.game', 'delete']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' threadrule 'com.example.game' 'delete'");
assert.strictEqual(C.command('threadrules'), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' threadrules");

// 参数拒绝：注入、越权、越界
const rejects = [
  () => C.command('mode', ['fast;reboot']),
  () => C.command('mode', ['Fast']),
  () => C.command('mode', []),
  () => C.command('rule', ['com.x$(id)', 'balance']),
  () => C.command('rule', ['com.example.app', 'delete;rm']),
  () => C.command('tune', ['maybe']),
  () => C.command('freq', ['cpu-policy0', '0', '1000']),
  () => C.command('freq', ['cpu-policy0', '2000', '1000']),
  () => C.command('freq', ['../../etc/passwd', '1', '2']),
  () => C.command('freq', ['cpu-policy0', '1e9', '2e9']),
  () => C.command('status', ['extra']),
  () => C.command('refresh', ['120', 'maybe']),
  () => C.command('refresh', ['120;reboot', 'on']),
  () => C.command('refresh', ['0', 'on']),
  () => C.command('refresh', ['480', 'on']),
  () => C.command('refresh', ['120']),
  () => C.command('refresh_manage', ['maybe']),
  () => C.command('thread', ['maybe']),
  () => C.command('threadrule', ['bad pkg', 'game']),
  () => C.command('threadrule', ['com.example.game', 'turbo']),
  () => C.command('unknown'),
];
for (const fn of rejects) assert.throws(fn, /拒绝|不能高于/);
// 包名与模式名严格受限，因此命令里只出现单引号包裹的字面量
assert.strictEqual(C.command('rule', ['com.a.b', 'balance']).endsWith("rule 'com.a.b' 'balance'"), true);

// 运行日志：读取 / 清空 / 写入
assert.strictEqual(C.command('logs'), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' logs");
assert.strictEqual(C.command('clearlog'), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' clearlog");
assert.strictEqual(C.command('logline', ['warn', 'refresh', '档位读不到']), "sh '/data/adb/modules/nanhe_ovo/script/control.sh' logline 'warn' 'refresh' '档位读不到'");
assert.strictEqual(C.command('logline', ['info', 'page', "多行\n内容\t制表"]).indexOf("'多行 内容 制表'") > 0, true);
for (const fn of [
  () => C.command('logline', ['silly', 'page', 'x']),
  () => C.command('logline', ['info', 'Bad Tag', 'x']),
  () => C.command('logline', ['info', 'page', '   ']),
  () => C.command('logline', ['info', 'page']),
]) assert.throws(fn, /拒绝/);

const logs = C.parseLogs([
  'log\t2026-11-16 00:21:08\tinfo\trefresh\t已应用 120Hz',
  'log\t2026-11-16 00:21:26\terror\tfreq\tcpu-policy6: maximum is not in frequency table',
  'log\t2026-11-16 00:21:2x\twat\tx\t级别未知按 info 处理',
  'log\t\tinfo\tx\t缺少时间丢弃',
  'ok\tlogs',
].join('\n'));
assert.deepStrictEqual(logs.map(r => [r.level, r.tag, r.message]), [
  ['info', 'refresh', '已应用 120Hz'],
  ['error', 'freq', 'cpu-policy6: maximum is not in frequency table'],
  ['info', 'x', '级别未知按 info 处理'],
]);

// 状态解析
const text = [
  'info\tmode\tbalance',
  'info\tmodes\tpowersave balance performance fast',
  'info\tversion\tv1.0.0',
  'device\tcpu-policy0\tCPU 策略 0\tkHz\t300000\t1800000\t1200000\t300000 600000 1200000 1800000',
  'device\tgpu-0\tGPU 0\tHz\t200000000\t800000000\t400000000\t200000000 400000000 800000000',
  'ok\tstatus',
].join('\n');
const parsed = C.parseStatus(text);
assert.deepStrictEqual(parsed.modes, ['powersave', 'balance', 'performance', 'fast']);
assert.strictEqual(parsed.info.version, 'v1.0.0');
assert.strictEqual(parsed.devices.length, 2);
assert.deepStrictEqual(parsed.devices[0].frequencies, [300000, 600000, 1200000, 1800000]);
assert.strictEqual(parsed.devices[1].unit, 'Hz');

// 单行频率读不到 / 非法时跳过该行，不能让一条坏数据拒收整包状态
assert.strictEqual(C.parseStatus(text.replace('300000\t1800000\t1200000', '1800000\t300000\t1200000')).devices.length, 1);
assert.strictEqual(C.parseStatus(text.replace('cpu-policy0', 'cpu-policy0;rm')).devices.length, 1);
assert.strictEqual(C.parseStatus('device\tcpu-policy0\tCPU\thtml\t1\t2\t3\t4').devices.length, 0);
assert.strictEqual(C.parseStatus(text + '\ndevice\tcpu-policy0\tdup\tkHz\t1\t2\t3\t4').devices.length, 2);
assert.strictEqual(C.parseStatus(text.replace('300000 600000 1200000 1800000', '300000 600000 abc')).devices.length, 1);
// 当前频率读不到时 min/max 仍保留，current 置 null
const noCurrent = C.parseStatus([
  'info\tmode\tbalance',
  'device\tcpu-policy0\tCPU 策略 0\tkHz\t300000\t1800000\tunknown\t300000 600000 1200000 1800000',
  'ok\tstatus',
].join('\n'));
assert.strictEqual(noCurrent.devices[0].current, null);

// 规则与应用解析
assert.deepStrictEqual(plain(C.parseRules('# c\n* balance\n- powersave\ncom.example.game performance')), {
  '*': 'balance', '-': 'powersave', 'com.example.game': 'performance',
});
assert.deepStrictEqual(plain(C.parseRules('com.x$(id) balance\ncom.ok.app fast')), { 'com.ok.app': 'fast' });

// 线程规则：只有块头注释被解析，包名/预设都要过白名单；规则块体不影响映射
assert.deepStrictEqual(plain(C.parseThreadRules(
  '# nanhe_threadrule pkg=com.example.game preset=game\n' +
  'com.example.game=p-core {\n\tUnityMain=hp-core\n}\n' +
  '# nanhe_threadrule pkg=com.example.reader preset=ui\n' +
  'com.example.reader=e-core,p-core {\n\tRenderThread=hp-core\n}\n' +
  '# nanhe_threadrule pkg=bad pkg preset=game\n'
)), { 'com.example.game': 'game', 'com.example.reader': 'ui' });
assert.deepStrictEqual(plain(C.parseThreadRules('')), {});
assert.deepStrictEqual(C.parseApps('com.b.app\ncom.a.app\ncom.a.app\njunk\n'), [
  { pkg: 'com.a.app', name: 'com.a.app', game: false },
  { pkg: 'com.b.app', name: 'com.b.app', game: false },
]);
assert.deepStrictEqual(C.parseApps('com.a.app\tgame\ncom.b.app'), [
  { pkg: 'com.a.app', name: 'com.a.app', game: true },
  { pkg: 'com.b.app', name: 'com.b.app', game: false },
]);
// 三列：包名 / 中文名 / game 标记；名称含空格时只按制表符分列
assert.deepStrictEqual(C.parseApps(
  'com.tencent.tmgp.sgame\t王者荣耀\tgame\n' +
  'com.miHoYo.bh3\t崩坏 3\tgame\n' +
  'com.example.reader\t示例阅读\tapp\n'
), [
  { pkg: 'com.miHoYo.bh3', name: '崩坏 3', game: true },
  { pkg: 'com.tencent.tmgp.sgame', name: '王者荣耀', game: true },
  { pkg: 'com.example.reader', name: '示例阅读', game: false },
]);
// 缺名称列时回退包名
assert.deepStrictEqual(C.parseApps('com.a.app\t\tgame'), [
  { pkg: 'com.a.app', name: 'com.a.app', game: true },
]);

// 频率换算与区间校验
assert.strictEqual(C.mhz(1800000, 'kHz'), '1,800 MHz');
assert.strictEqual(C.mhz(903000000, 'Hz'), '903 MHz');
const dev = parsed.devices[0];
assert.deepStrictEqual(C.validateRange(dev, '600000', '1200000'), ['600000', '1200000']);
assert.throws(() => C.validateRange(dev, '500000', '1200000'), /频率表/);
assert.throws(() => C.validateRange(dev, '1800000', '600000'), /高于/);

// 机型信息解析：只接受 kv 三段以上，非法 section 丢弃
const dinfo = C.parseDeviceInfo([
  'kv\tdevice\t品牌\tREDMI',
  'kv\tscreen\t分辨率\t1880 × 3008',
  'kv\tbattery\t技术\tLi-poly',
  'kv\tdevice\t空值',
  'kv\tDevice\t大小写\tREDMI',
  'junk\tline',
  'ok\tdeviceinfo',
].join('\n'));
assert.deepStrictEqual(dinfo.map(r => [r.section, r.label, r.value]), [
  ['device', '品牌', 'REDMI'],
  ['screen', '分辨率', '1880 × 3008'],
  ['battery', '技术', 'Li-poly'],
]);
assert.deepStrictEqual(C.numbers('30 48 60 120 abc 0 -1 7.5'), [30, 48, 60, 120]);

// 桥接：成功、失败、超时、缺桥接
(async () => {
  const host = {
    ksu: {
      exec(cmd, opts, name) {
        setTimeout(() => {
          if (cmd === 'id -u') host[name](0, '0', '');
          else if (cmd.indexOf('apps') !== -1) host[name](1, '', '出错');
          else host[name](0, 'ok', '');
        }, 5);
      },
    },
  };
  const ok = await C.exec(host, C.command('status'));
  assert.strictEqual(ok.stdout, 'ok');
  await assert.rejects(() => C.exec(host, C.command('apps')), /退出码 1/);
  await assert.rejects(() => C.exec({}, C.command('status')), /KernelSU/);
  await assert.rejects(() => C.exec({ ksu: { exec() {} } }, C.command('status'), 50), /超时/);
  console.log('PASS core.js: 命令构造/拒绝/解析/换算/桥接');
})().catch(e => { console.error(e); process.exit(1); });
