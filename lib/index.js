/**
 * @119-svg/dsh-restart · 宿主半区
 *
 * 两个本地接口（都走插件自己的 loopback 路由，不碰 DSH 的鉴权面）：
 *   POST /api/dsh-restart/status      查看脚本位置 / 日志路径 / 平台支持情况
 *   POST /api/dsh-restart/restartApp  发起整机重启；body 带 {"dryRun":true} 则只演练
 *
 * 为什么这么绕——每条都是实测踩出来的，改代码前请先读 README 的「坑」一节：
 *   1. 宿主进程里直接调 Node 原生 child_process.spawn 会被沙箱**同步抛 EPERM**；
 *      唯一可行通道是 DSH 自带的受管子进程服务 ctx.get('subprocess')。
 *   2. subprocess.spawn 的 graceMs 是**必填项**（官方 validateSubprocessSpec 会校验正有限数）。
 *   3. DSH 的子进程活在**受管容器**里，宿主退出时容器被清理、成员连其后代一起被杀。
 *      所以真正干活的进程不能由本插件直接启动——脚本里用 WMI 创建它（父进程变成 WmiPrvSE），
 *      否则会表现为「只关闭、不打开」。
 */
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-restart'
export const inject = ['webServer']

const API = '/api/dsh-restart'
const HERE = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(HERE, '..', 'scripts', 'restart-dsh.ps1')
const LOG = join(process.env.USERPROFILE ?? process.env.HOME ?? '', '.dsh', 'dsh-restart.log')

/**
 * 发起整机重启。
 * @param ctx - 插件上下文
 * @param options.dryRun - true 时给脚本加 -DryRun：只记录计划，不杀进程、不重启
 */
async function restartApp(ctx, options = {}) {
  const subprocess = ctx.get?.('subprocess')
  if (subprocess === undefined || typeof subprocess.spawn !== 'function') {
    throw new Error('拿不到 DSH 的 subprocess 服务，无法发起重启')
  }
  if (!existsSync(SCRIPT)) throw new Error(`找不到重启脚本：${SCRIPT}`)

  const powershell = await subprocess.resolveExecutable('powershell.exe')
  const argv = [powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT]
  if (options.dryRun === true) argv.push('-DryRun')
  const handle = subprocess.spawn({
    argv,
    cwd: dirname(SCRIPT),
    stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } },
    // 必填：省略即抛 "subprocess graceMs must be a positive finite number…"
    graceMs: 5000,
  })

  // 脚本的 phase 1 亚秒级退出（真正干活的是它用 WMI 拉起的 worker）。
  // 有界等待 + 如实上抛：spawn 失败被吞成「已受理」是踩过的坑。
  const outcome = await Promise.race([
    Promise.resolve(handle.done).then(
      (value) => ({ settled: true, value }),
      (error) => ({ settled: true, error }),
    ),
    new Promise((resolve) => setTimeout(() => resolve({ settled: false }), 8000)),
  ])
  const stderr = String(handle.collected?.stderr?.readFrom(0)?.text ?? '').trim()
  if (outcome.settled && outcome.error !== undefined) {
    throw new Error(`重启脚本启动失败：${String(outcome.error?.message ?? outcome.error)}`)
  }
  const exitCode = outcome.settled ? outcome.value?.exitCode : null
  if (outcome.settled && exitCode !== 0 && exitCode !== null && exitCode !== undefined) {
    throw new Error(`重启脚本退出码 ${exitCode}${stderr ? `：${stderr.slice(0, 300)}` : ''}`)
  }
  return { accepted: true, dryRun: options.dryRun === true, script: SCRIPT, exitCode: exitCode ?? null }
}

export function apply(ctx) {
  const actions = {
    status: async () => ({
      script: SCRIPT,
      scriptExists: existsSync(SCRIPT),
      log: LOG,
      platform: process.platform,
      supported: process.platform === 'win32',
    }),
    restartApp: async (args) => restartApp(ctx, { dryRun: args?.dryRun === true }),
  }

  const json = (res, status, body) => {
    const text = JSON.stringify(body)
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(text),
      'cache-control': 'no-store',
    })
    res.end(text)
  }

  const isLoopback = (req) => {
    const address = req.socket?.remoteAddress ?? ''
    return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
  }

  /** 浏览器请求带 Origin；只接受本机来源（脚本/curl 不带 Origin，放行） */
  const originAllowed = (req) => {
    const origin = req.headers?.origin
    if (!origin) return true
    try {
      const host = new URL(String(origin)).hostname
      return host === '127.0.0.1' || host === 'localhost' || host === '::1' || host === '[::1]'
    } catch {
      return false
    }
  }

  const readBody = async (req) => {
    const chunks = []
    let size = 0
    for await (const chunk of req) {
      size += chunk.length
      if (size > 65536) throw new Error('请求体过大')
      chunks.push(chunk)
    }
    const raw = Buffer.concat(chunks).toString('utf8').trim()
    if (!raw) return {}
    try { return JSON.parse(raw) } catch { throw new Error('请求体不是合法 JSON') }
  }

  ctx.inject(['webServer'], (scope) => {
    scope.effect(() => {
      const disposers = Object.entries(actions).map(([action, run]) => scope.webServer.register({
        kind: 'exact',
        path: `${API}/${action}`,
        handler: async (req, res) => {
          if (!isLoopback(req)) return json(res, 403, { ok: false, error: '仅允许本机请求' })
          if (!originAllowed(req)) return json(res, 403, { ok: false, error: '来源不被允许' })
          if (req.method !== 'POST') return json(res, 405, { ok: false, error: '仅支持 POST' })
          // 只收 application/json：text/plain 是 CORS 简单请求，会绕过预检，必须自己挡
          const type = String(req.headers?.['content-type'] ?? '')
          if (!type.includes('application/json')) {
            return json(res, 415, { ok: false, error: '仅接受 application/json' })
          }
          try {
            json(res, 200, { ok: true, value: await run(await readBody(req)) })
          } catch (error) {
            json(res, 400, { ok: false, error: String(error?.message ?? error) })
          }
        },
      }))
      return () => { for (const dispose of disposers) dispose() }
    }, 'dsh-restart: 本地重启接口')
  })
}
